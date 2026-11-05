// Module Lua « organum » : le moteur d'Aeolus dans redbean.
//
// redbean sert chaque connexion dans un processus fils. Le moteur ne peut
// donc vivre que dans le processus principal : organum.demarrer(), appelé
// depuis .init.lua, y crée le moteur et un fil audio. Les fils de requêtes
// communiquent avec lui par deux canaux créés avant leur fork :
//
//   - un tube, où ils écrivent des commandes de taille fixe (écritures
//     atomiques), lues par le fil audio entre deux tampons ;
//   - une mémoire partagée, où le fil audio publie l'état (jeux, gains,
//     volume…) avec un numéro de séquence incrémenté à chaque changement.
//
// Un seul fil touche au moteur : le MIDI, les commandes et le rendu sont
// traités à la suite dans la boucle audio, sans verrou.
#include "libc/calls/syscall-sysv.internal.h"
#include "libc/dce.h"
#include "third_party/lua/lauxlib.h"
#include "third_party/lua/lua.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#include "../moteur/api/aeolus_c.h"
#include "../plateforme/audio.h"
#include "../plateforme/midi.h"

#define MAX_DIVISIONS 8
#define MAX_JEUX 64
#define MAX_NOM 48
#define MAX_ASSOCIATIONS 16
#define MAX_LIENS 8
#define TOUS_CANAUX 16
#define PERIPH_MAX 200
#define ERREUR_MAX 256

enum {
  CMD_JEU, CMD_GAIN, CMD_VOLUME, CMD_REVERB, CMD_MIDI, CMD_PANIQUE,
  CMD_CANAUX_DIVISION, CMD_CANAUX_CONTROLE, CMD_CANAUX_EXPRESSION,
  CMD_ASSOCIATION, CMD_NB_ASSOCIATIONS, CMD_LIEN, CMD_QUALITE,
  CMD_LIMITEUR, CMD_TETE, CMD_RECONFIG,
};

// Demande de reconfiguration audio : le tube ne transporte que des
// commandes de taille fixe, le nom du périphérique passe donc par le mmap
// partagé, sous verrou atomique.
struct demande_audio {
  int taux, periode;
  char peripherique[PERIPH_MAX + 1];
};

struct commande {
  unsigned char type, a, b, c, d;
  unsigned short masque;
  float valeur;
};

// Association d'un contrôleur MIDI (CC) à un réglage : la molette de
// modulation (CC 1) vers le volume, par exemple. Traitée avant le moteur.
enum { CIBLE_AUCUNE, CIBLE_VOLUME, CIBLE_REVERB, CIBLE_GAIN };

struct association {
  unsigned char canal;  // 0-15, ou TOUS_CANAUX
  unsigned char cc;
  unsigned char cible;
  unsigned char division;  // pour CIBLE_GAIN
};

struct etat {
  atomic_uint seq;
  int ndivisions;
  struct {
    char nom[MAX_NOM];
    float gain;
    int canaux;  // masque des canaux MIDI qui jouent sur ce clavier
    int nliens;  // accouplements : ce clavier fait aussi parler ceux-ci
    struct {
      int division;
      unsigned char actif;
    } liens[MAX_LIENS];
    int njeux;
    struct {
      char nom[MAX_NOM];
      unsigned char actif;
    } jeux[MAX_JEUX];
  } divisions[MAX_DIVISIONS];
  float volume, reverb;
  // Réglages de qualité publiés par le moteur (voir aeolus_qualite).
  int bruit_attaque, instabilite, spatialisation, polyphonie_max;
  // Tête de réverbération : valeur effective (option + ORGANUM_REVERB_TETE)
  // et indique si la variable d'environnement impose cette valeur.
  int tete_reverb, tete_reverb_impose;
  int canaux_controle, canaux_expression;
  int nassociations;
  struct association associations[MAX_ASSOCIATIONS];
  // Dernier contrôleur reçu, pour l'apprentissage depuis la page MIDI.
  int dernier_canal, dernier_cc, derniere_valeur;
  int xruns;
  // Mesure de charge du fil audio : charge et charge_pointe sont écrites
  // sans réveiller les attentes ; charge_niveau ne change qu'au plus une
  // fois par seconde et fait alors avancer seq.
  int charge, charge_pointe, charge_evaluee, charge_niveau;
  int xruns_recents;  // xruns des 60 dernières secondes (hors changements)
  int temps_reel;  // le fil audio a obtenu SCHED_FIFO
  int etape, netapes;  // combinaison courante (séquenceur), à partir de 0
  int midi_client, midi_port;
  int taux;
  int periode, nb_periodes;  // effectifs de l'ouverture courante
  char peripherique[PERIPH_MAX + 1];  // effectif ("" = défaut)
  int limiteur;  // effectif
  char audio_erreur[ERREUR_MAX];  // dernier échec de reconfiguration
  int temperament;  // valeur effective (enum Scale::Type)
  char temperament_erreur[ERREUR_MAX];  // dernier échec d'application
  unsigned erreurs_ecriture;  // audio_ecrire() a renvoyé une erreur
};

// L'activité MIDI est hors de struct etat pour que la copie cohérente de
// l_etat (memcpy sous seq) ne copie jamais d'objet atomique : atomics ne se
// prêtent pas à memcpy, et ce champ évolue sans incrémenter seq. Les deux
// structures vivent dans le même mmap partagé.
struct etat_partage {
  struct etat etat;
  atomic_uint canaux_actifs;  // bit n = canal n+1, éphémère
  // Demandes de reconfiguration audio : le demandeur incrémente demandes
  // avant d'envoyer CMD_RECONFIG, le fil audio incrémente traitees après
  // chaque demande traitée, succès comme échec. Leur écart pilote
  // qualite.application (une demande fusionnée reste comptée). Hors de
  // struct etat, pour ne jamais être copiés par le memcpy de l_etat.
  atomic_uint demandes_audio, traitees_audio;
  struct demande_audio demande_audio;
  atomic_int verrou_demande;
  // Tempérament : même principe, mais l'application se fait dans un fil de
  // calcul dédié (jamais dans le fil audio). Le verrou protège la valeur
  // demandée et les compteurs, pour qu'une demande ne soit jamais comptée
  // sans que le fil de calcul puisse la voir.
  atomic_uint demandes_temperament, traitees_temperament;
  atomic_int temperament_demande;  // -1 : aucune
  atomic_int verrou_temperament;
};

static struct etat_partage *g_partage;
static struct etat *g_etat;  // &g_partage->etat, partagée avec les fils
static int g_tube[2] = {-1, -1};
static void *g_moteur;
static audio_t *g_audio;
static midi_t *g_midi;
static int g_periode;
static int g_taux;
static char g_peripherique[PERIPH_MAX + 1];
static int g_limiteur = 1;
static char g_audio_erreur[ERREUR_MAX];
static int g_xruns_base;  // xruns cumulés des descripteurs déjà fermés
static struct demande_audio g_demande_pendante;
static int g_demande_pendante_valide;
static long g_dernier_essai_audio;
static unsigned g_erreurs_ecriture;  // fil audio uniquement, publié par publier()
static int g_maitre;  // processus qui fait tourner le moteur
// Protège g_moteur entre le fil audio (recréation au changement de taux), le
// fil de calcul du tempérament et le processus principal qui le sérialise
// (l_sauvegarder).
static pthread_mutex_t g_moteur_verrou = PTHREAD_MUTEX_INITIALIZER;
// Fil de calcul du tempérament : il reconstruit le jeu de tuyaux parallèle
// hors du fil audio, puis bascule ; le son tenu continue pendant ce temps.
static pthread_t g_fil_temperament;
static int g_fil_temperament_demarre;
static atomic_int g_temperament_fin;

static void demarrer_fil_temperament(void);
static void arreter_fil_temperament(void);
// Propres au fil audio ; publiées dans g_etat.
static struct association g_associations[MAX_ASSOCIATIONS];
static int g_nassociations;
static int g_dernier[3] = {-1, -1, -1};
// Horloge du fil audio : échantillons écoulés et échéance d'activité par
// canal. La mesure de charge appelle clock_gettime autour du rendu : sous
// Linux cosmopolitan résout __vdso_clock_gettime (libc/intrin/
// clock_gettime.c), donc pas d'appel système dans la boucle.
static unsigned long long g_echantillons;
static unsigned long long g_echeances[16];

// Mesure de charge, fil audio uniquement. Aucune allocation, aucun verrou,
// aucun flottant : deux lectures d'horloge et de l'arithmétique entière par
// tampon. Les xruns récents tiennent dans un anneau fixe de 60 secondes.
#define XRUNS_ANNEAU 60
// Fenêtre d'exclusion après un réglage (période, tête, périphérique, taux) :
// les xruns de l'ouverture ou de la bascule y sont ignorés. Trois secondes
// couvrent les mesures réelles, où une seconde laissait encore passer un xrun.
#define XRUNS_BLOCAGE_SECONDES 3
// Moyennes de charge par seconde de jeu, sur les 60 dernières secondes : la
// pointe est leur maximum. Un tampon préempté seul ne suffit donc plus à
// passer la puce au rouge.
#define MESURE_MOYENNES 60
static unsigned long long g_mesure_prochaine_seconde;
static unsigned long long g_mesure_echantillons_joues;
static unsigned g_mesure_somme;
static unsigned g_mesure_tampons_seconde;
static unsigned g_mesure_somme_jeu;
static unsigned g_mesure_tampons_jeu;
static unsigned g_mesure_moyennes[MESURE_MOYENNES];
static int g_mesure_moyennes_pos;
static unsigned g_mesure_pointe;
static int g_mesure_evaluee;
static int g_xruns_vus;
static unsigned long long g_xruns_blocage;
static unsigned short g_xruns_anneau[XRUNS_ANNEAU];
static int g_xruns_anneau_pos;
static int g_xruns_recents;

// Règle de la puce, calculée sur des entiers : jamais de vert sans mesure.
static int calculer_charge_niveau(int pointe, int recents, int evaluee) {
  if (pointe >= 90 || recents >= 3) return 3;
  if (pointe >= 65 || recents >= 1) return 2;
  if (evaluee && recents == 0) return 1;
  return 0;
}

// Nouveau réglage audio ou de qualité : la pointe repart de zéro et aucune
// couleur ne doit être affichée avant une seconde de jeu.
static void mesure_reinitialiser(void) {
  g_mesure_pointe = 0;
  g_mesure_echantillons_joues = 0;
  g_mesure_evaluee = 0;
  g_mesure_somme_jeu = 0;
  g_mesure_tampons_jeu = 0;
  memset(g_mesure_moyennes, 0, sizeof(g_mesure_moyennes));
  g_mesure_moyennes_pos = 0;
  g_mesure_somme = 0;
  g_mesure_tampons_seconde = 0;
  memset(g_xruns_anneau, 0, sizeof(g_xruns_anneau));
  g_xruns_anneau_pos = 0;
  g_xruns_recents = 0;
  g_etat->xruns_recents = 0;
  // La première moyenne ne comptera qu'une seconde pleine après ce réglage.
  g_mesure_prochaine_seconde =
      g_echantillons + (unsigned long long)g_taux;
  g_etat->charge_pointe = 0;
  g_etat->charge_evaluee = 0;
  if (g_etat->charge_niveau != 0) {
    g_etat->charge_niveau = 0;
    atomic_fetch_add_explicit(&g_etat->seq, 1, memory_order_release);
  }
}

// État de mesure remis à zéro au démarrage (le mmap est déjà remis à zéro).
static void mesure_init(void) {
  g_mesure_prochaine_seconde = 0;
  g_mesure_echantillons_joues = 0;
  g_mesure_somme = 0;
  g_mesure_tampons_seconde = 0;
  g_mesure_somme_jeu = 0;
  g_mesure_tampons_jeu = 0;
  memset(g_mesure_moyennes, 0, sizeof(g_mesure_moyennes));
  g_mesure_moyennes_pos = 0;
  g_mesure_pointe = 0;
  g_mesure_evaluee = 0;
  g_xruns_vus = 0;
  g_xruns_blocage = 0;
  memset(g_xruns_anneau, 0, sizeof(g_xruns_anneau));
  g_xruns_anneau_pos = 0;
  g_xruns_recents = 0;
}

// Un fils issu du fork hérite des descripteurs et des mappages PCM du
// processus principal. Les fermer ici, sans aucun appel ALSA (jamais
// snd_pcm_close/drop/ioctl, qui arrêteraient le flux du parent), libère le
// périphérique pour la réouverture. Ne touche ni /dev/snd/seq ni le tube.
#define CHEMIN_MAX 4096

static int commence_par(const char *s, const char *prefixe) {
  return strncmp(s, prefixe, strlen(prefixe)) == 0;
}

static void fermer_pcm_herites(void) {
  DIR *d = opendir("/proc/self/fd");
  if (!d) return;
  int dfd = dirfd(d);
  struct dirent *e;
  char lien[64], cible[CHEMIN_MAX];
  while ((e = readdir(d))) {
    int fd = atoi(e->d_name);
    if (fd <= 2 || fd == dfd) continue;
    snprintf(lien, sizeof(lien), "/proc/self/fd/%d", fd);
    ssize_t n = readlink(lien, cible, sizeof(cible) - 1);
    if (n <= 0) continue;
    cible[n] = '\0';
    if (commence_par(cible, "/dev/snd/pcm")) close(fd);
  }
  closedir(d);
}

#define MAX_ZONES_PCM 16

struct zone_pcm {
  unsigned long debut, fin;
  char chemin[64];
};

static int collecter_zone(char *ligne, struct zone_pcm *zones, int nzones) {
  unsigned long debut, fin;
  if (sscanf(ligne, "%lx-%lx", &debut, &fin) != 2 || fin <= debut) return nzones;
  char *chemin = strchr(ligne, '/');
  if (!chemin || !commence_par(chemin, "/dev/snd/pcm")) return nzones;
  if (nzones >= MAX_ZONES_PCM) {
    fprintf(stderr, "organum : trop de zones PCM dans /proc/self/maps\n");
    return nzones;
  }
  zones[nzones].debut = debut;
  zones[nzones].fin = fin;
  strlcpy(zones[nzones].chemin, chemin, sizeof(zones[nzones].chemin));
  return nzones + 1;
}

static void oublier_audio_fils(void) {
  if (!IsLinux()) return;

  // Deux temps : collecter d'abord toutes les zones (la lecture de
  // /proc/self/maps ne doit pas être perturbée par des munmap), fermer le
  // fichier, puis libérer.
  struct zone_pcm zones[MAX_ZONES_PCM];
  int nzones = 0;
  int fd = open("/proc/self/maps", O_RDONLY);
  if (fd >= 0) {
    char buf[8192];
    size_t len = 0;
    for (;;) {
      ssize_t n = read(fd, buf + len, sizeof(buf) - len - 1);
      if (n <= 0) break;
      len += (size_t)n;
      buf[len] = '\0';
      char *p = buf, *nl;
      while ((nl = strchr(p, '\n'))) {
        *nl = '\0';
        nzones = collecter_zone(p, zones, nzones);
        p = nl + 1;
      }
      size_t reste = strlen(p);
      memmove(buf, p, reste);
      len = reste;
      if (len == sizeof(buf) - 1) len = 0;  // ligne anormalement longue
    }
    if (len) {
      buf[len] = '\0';
      nzones = collecter_zone(buf, zones, nzones);
    }
    close(fd);
  }

  fermer_pcm_herites();

  // Ces zones ont été créées par libasound via cosmo_dlopen, hors de la
  // table __maps de cosmopolitan : munmap() passerait par __munmap et ne
  // les libérerait pas. sys_munmap() (munmap-sysv.c) bypasse memtrack.
  for (int i = 0; i < nzones; ++i) {
    int rc = sys_munmap((void *)zones[i].debut,
                        (size_t)(zones[i].fin - zones[i].debut));
    if (rc) {
      int e = rc < 0 ? -rc : errno;
      fprintf(stderr, "organum : munmap %s (%#lx-%#lx) impossible : errno %d (%s)\n",
              zones[i].chemin, zones[i].debut, zones[i].fin, e, strerror(e));
    }
  }
}

// Libère tout ce que l_demarrer a alloué, pour qu'un second appel puisse
// réessayer avec d'autres réglages (repli de init.moon après un échec
// d'ouverture audio ou MIDI). Sans cela, g_etat resterait non nul et
// l_demarrer refuserait de redémarrer.
static void liberer_demarrage(void) {
  arreter_fil_temperament();
  if (g_midi) {
    midi_fermer(g_midi);
    g_midi = NULL;
  }
  if (g_audio) {
    audio_fermer(g_audio);
    g_audio = NULL;
  }
  if (g_moteur) {
    aeolus_detruire(g_moteur);
    g_moteur = NULL;
  }
  if (g_tube[0] >= 0) {
    close(g_tube[0]);
    g_tube[0] = -1;
  }
  if (g_tube[1] >= 0) {
    close(g_tube[1]);
    g_tube[1] = -1;
  }
  if (g_partage) {
    munmap(g_partage, sizeof(*g_partage));
    g_partage = NULL;
  }
  g_etat = NULL;
}

static void copier_nom(char *dst, const char *src) {
  if (!src) src = "";
  strlcpy(dst, src, MAX_NOM);
  free((void *)src);  // l'API C renvoie des copies allouées
}

// Relit l'état du moteur et publie un nouveau numéro de séquence si
// quelque chose a changé. Appelé par le fil audio uniquement.
static void publier(void) {
  struct etat *e = g_etat;
  int change = 0, registration = 0;
  for (int d = 0; d < e->ndivisions; ++d) {
    float g = aeolus_lire_gain(g_moteur, d);
    if (g != e->divisions[d].gain) e->divisions[d].gain = g, change = 1;
    for (int l = 0; l < e->divisions[d].nliens; ++l) {
      unsigned char a = aeolus_lien_actif(g_moteur, d, l);
      if (a != e->divisions[d].liens[l].actif) e->divisions[d].liens[l].actif = a, change = registration = 1;
    }
    int c = aeolus_canaux_division(g_moteur, d);
    if (c != e->divisions[d].canaux) e->divisions[d].canaux = c, change = 1;
    for (int j = 0; j < e->divisions[d].njeux; ++j) {
      unsigned char a = aeolus_jeu_actif(g_moteur, d, j);
      if (a != e->divisions[d].jeux[j].actif)
        e->divisions[d].jeux[j].actif = a, change = registration = 1;
    }
  }
  float v = aeolus_lire_volume(g_moteur), r = aeolus_lire_reverb(g_moteur);
  int x = g_xruns_base + (g_audio ? audio_xruns(g_audio) : 0);
  if (v != e->volume) e->volume = v, change = 1;
  if (r != e->reverb) e->reverb = r, change = 1;
  if (x != e->xruns) e->xruns = x, change = 1;
  if (g_taux != e->taux) e->taux = g_taux, change = 1;
  if (g_periode != e->periode) e->periode = g_periode, change = 1;
  if (g_limiteur != e->limiteur) e->limiteur = g_limiteur, change = 1;
  if (strcmp(g_peripherique, e->peripherique) != 0) {
    strlcpy(e->peripherique, g_peripherique, sizeof(e->peripherique));
    change = 1;
  }
  if (strcmp(g_audio_erreur, e->audio_erreur) != 0) {
    strlcpy(e->audio_erreur, g_audio_erreur, sizeof(e->audio_erreur));
    change = 1;
  }
  {
    int qualite[4] = {
        aeolus_lire_qualite(g_moteur, 0), aeolus_lire_qualite(g_moteur, 1),
        aeolus_lire_qualite(g_moteur, 2), aeolus_lire_qualite(g_moteur, 3)};
    if (qualite[0] != e->bruit_attaque) e->bruit_attaque = qualite[0], change = 1;
    if (qualite[1] != e->instabilite) e->instabilite = qualite[1], change = 1;
    if (qualite[2] != e->spatialisation) e->spatialisation = qualite[2], change = 1;
    if (qualite[3] != e->polyphonie_max) e->polyphonie_max = qualite[3], change = 1;
  }
  {
    int tete = aeolus_lire_reverb_tete(g_moteur);
    if (tete != e->tete_reverb) e->tete_reverb = tete, change = 1;
  }
  {
    int temperament = aeolus_lire_temperament(g_moteur);
    if (temperament != e->temperament)
      e->temperament = temperament, change = 1;
  }
  if (g_erreurs_ecriture != e->erreurs_ecriture) {
    e->erreurs_ecriture = g_erreurs_ecriture;
    change = 1;
  }
  int etape = aeolus_etape(g_moteur);
  if (etape != e->etape) e->etape = etape, change = 1;
  int cc = aeolus_canaux_controle(g_moteur), ce = aeolus_canaux_expression(g_moteur);
  if (cc != e->canaux_controle) e->canaux_controle = cc, change = 1;
  if (ce != e->canaux_expression) e->canaux_expression = ce, change = 1;
  // Activité éphémère : publiée à part, sans toucher à seq.
  unsigned actifs = 0;
  for (int c = 0; c < 16; ++c)
    if (g_echeances[c] > g_echantillons) actifs |= 1u << c;
  atomic_uint *canaux_actifs = &g_partage->canaux_actifs;
  if (actifs != atomic_load_explicit(canaux_actifs, memory_order_relaxed))
    atomic_store_explicit(canaux_actifs, actifs, memory_order_relaxed);
  if (g_nassociations != e->nassociations ||
      memcmp(g_associations, e->associations, sizeof(g_associations))) {
    memcpy(e->associations, g_associations, sizeof(g_associations));
    e->nassociations = g_nassociations;
    change = 1;
  }
  if (g_dernier[0] != e->dernier_canal || g_dernier[1] != e->dernier_cc ||
      g_dernier[2] != e->derniere_valeur) {
    e->dernier_canal = g_dernier[0];
    e->dernier_cc = g_dernier[1];
    e->derniere_valeur = g_dernier[2];
    change = 1;
  }
  // Une combinaison retient ce qu'on tire tant qu'elle est sélectionnée,
  // même si l'on quitte organum sans changer d'étape.
  if (registration) aeolus_capturer_etape(g_moteur);
  if (change) atomic_fetch_add_explicit(&e->seq, 1, memory_order_release);
}

static void panique(void) {
  for (int canal = 0; canal < 16; ++canal) {
    unsigned char m[3] = {0xB0 | canal, 123, 0};
    aeolus_midi(g_moteur, m, 3);
  }
}

static void appliquer(const struct commande *c) {
  switch (c->type) {
    case CMD_JEU:
      aeolus_jeu(g_moteur, c->a, c->b, c->c);
      break;
    case CMD_GAIN:
      aeolus_gain(g_moteur, c->a, c->valeur);
      break;
    case CMD_VOLUME:
      aeolus_volume(g_moteur, c->valeur);
      break;
    case CMD_REVERB:
      aeolus_reverb(g_moteur, c->valeur);
      break;
    case CMD_MIDI: {
      unsigned char m[3] = {c->a, c->b, c->c};
      aeolus_midi(g_moteur, m, 3);
      break;
    }
    case CMD_PANIQUE:
      panique();
      break;
    case CMD_CANAUX_DIVISION:
      aeolus_fixer_canaux_division(g_moteur, c->a, c->masque);
      break;
    case CMD_CANAUX_CONTROLE:
      aeolus_fixer_canaux_controle(g_moteur, c->masque);
      break;
    case CMD_CANAUX_EXPRESSION:
      aeolus_fixer_canaux_expression(g_moteur, c->masque);
      break;
    case CMD_ASSOCIATION:
      if (c->a < MAX_ASSOCIATIONS)
        g_associations[c->a] = (struct association){c->b, c->c, c->d, c->masque};
      break;
    case CMD_LIEN:
      aeolus_lien(g_moteur, c->a, c->b, c->c);
      break;
    case CMD_NB_ASSOCIATIONS:
      g_nassociations = c->a > MAX_ASSOCIATIONS ? MAX_ASSOCIATIONS : c->a;
      memset(g_associations + g_nassociations, 0,
             (MAX_ASSOCIATIONS - g_nassociations) * sizeof(*g_associations));
      break;
    case CMD_QUALITE:
      // La valeur passe par masque (16 bits) : polyphonie_max va jusqu'à 512,
      // que le champ b (8 bits) tronquerait.
      aeolus_qualite(g_moteur, c->a, c->masque);
      mesure_reinitialiser();
      break;
    case CMD_LIMITEUR:
      g_limiteur = c->a != 0;
      aeolus_limiteur(g_moteur, g_limiteur);
      mesure_reinitialiser();
      break;
    case CMD_TETE:
      // ORGANUM_REVERB_TETE reste prioritaire.
      if (!g_etat->tete_reverb_impose)
        aeolus_reverb_tete(g_moteur, c->a != 0);
      // Une bascule de tête produit un xrun connu : ignorer ceux des trois
      // secondes qui suivent.
      g_xruns_blocage =
          g_echantillons + (unsigned long long)g_taux * XRUNS_BLOCAGE_SECONDES;
      mesure_reinitialiser();
      break;
    case CMD_RECONFIG:
      // Traité par boucle_audio, qui possède les tampons de rendu.
      break;
  }
}

// Applique les associations à un contrôleur ; vrai s'il est consommé (il
// ne parvient alors pas au moteur).
static int associer(unsigned char statut, unsigned char cc, unsigned char v) {
  int canal = statut & 0x0F, pris = 0;
  g_dernier[0] = canal, g_dernier[1] = cc, g_dernier[2] = v;
  for (int i = 0; i < g_nassociations; ++i) {
    struct association *a = &g_associations[i];
    if (a->cc != cc || (a->canal != TOUS_CANAUX && a->canal != canal)) continue;
    float x = v / 127.0f;
    switch (a->cible) {
      case CIBLE_VOLUME: aeolus_volume(g_moteur, x); pris = 1; break;
      case CIBLE_REVERB: aeolus_reverb(g_moteur, x); pris = 1; break;
      case CIBLE_GAIN: aeolus_gain(g_moteur, a->division, x); pris = 1; break;
    }
  }
  return pris;
}


// --- Reconfiguration audio à chaud, dans le fil audio uniquement ----------

static void verrou_prendre(atomic_int *v) {
  int attendu = 0;
  while (!atomic_compare_exchange_weak_explicit(
      v, &attendu, 1, memory_order_acquire, memory_order_relaxed))
    attendu = 0;
}

static void verrou_rendre(atomic_int *v) {
  atomic_store_explicit(v, 0, memory_order_release);
}

// --- Calcul du tempérament hors du fil audio ------------------------------

// Une demande est déposée par un processus de requête (ou la fenêtre), puis
// traitée ici : retunePipes écrit dans le jeu de tuyaux inactif, prepareToPlay
// le reconstruit, et la bascule atomique de _pipeSetIndex n'a lieu qu'une
// fois le nouveau jeu prêt. Le fil audio n'alloue ni n'attend jamais.
static void *boucle_temperament(void *arg) {
  (void)arg;
  while (!atomic_load_explicit(&g_temperament_fin, memory_order_acquire)) {
    int type = atomic_load_explicit(&g_partage->temperament_demande,
                                    memory_order_acquire);
    if (type < 0) {
      struct timespec pause = {0, 10 * 1000 * 1000};
      nanosleep(&pause, NULL);
      continue;
    }
    // Capturer aussi le nombre de demandes déjà déposées, sous le même
    // verrou : les demandes plus récentes resteront comptées et seront
    // traitées au tour suivant (seule la dernière valeur compte).
    verrou_prendre(&g_partage->verrou_temperament);
    type = atomic_load_explicit(&g_partage->temperament_demande,
                                memory_order_acquire);
    unsigned demandees =
        atomic_load_explicit(&g_partage->demandes_temperament,
                             memory_order_acquire);
    if (type >= 0)
      atomic_store_explicit(&g_partage->temperament_demande, -1,
                            memory_order_release);
    verrou_rendre(&g_partage->verrou_temperament);
    if (type < 0) continue;

    int ok;
    int effectif = -1;
    pthread_mutex_lock(&g_moteur_verrou);
    ok = g_moteur ? aeolus_temperament(g_moteur, type) : -1;
    if (ok == 0 && g_moteur) effectif = aeolus_lire_temperament(g_moteur);
    pthread_mutex_unlock(&g_moteur_verrou);

    if (ok == 0) {
      // Publier la valeur effective AVANT de marquer la demande traitée :
      // sinon une lecture d'état pourrait voir « application » à faux avec
      // l'ancien tempérament, le fil audio n'ayant pas encore publié.
      if (effectif >= 0) g_etat->temperament = effectif;
      g_etat->temperament_erreur[0] = '\0';
    } else {
      snprintf(g_etat->temperament_erreur,
               sizeof(g_etat->temperament_erreur),
               "application du tempérament %d impossible", type);
    }
    // Les demandes couvertes par ce calcul sont traitées, y compris celles
    // qui ont été fusionnées en une seule valeur. Les suivantes restent
    // comptées et « application » reste vrai.
    verrou_prendre(&g_partage->verrou_temperament);
    atomic_store_explicit(&g_partage->traitees_temperament, demandees,
                          memory_order_release);
    verrou_rendre(&g_partage->verrou_temperament);
    atomic_fetch_add_explicit(&g_etat->seq, 1, memory_order_release);
  }
  return NULL;
}

static void demarrer_fil_temperament(void) {
  atomic_store(&g_temperament_fin, 0);
  if (pthread_create(&g_fil_temperament, NULL, boucle_temperament, NULL) != 0)
    return;
  g_fil_temperament_demarre = 1;
}

static void arreter_fil_temperament(void) {
  if (!g_fil_temperament_demarre) return;
  atomic_store_explicit(&g_temperament_fin, 1, memory_order_release);
  pthread_join(g_fil_temperament, NULL);
  g_fil_temperament_demarre = 0;
}

static void copier_demande(struct demande_audio *d) {
  if (!g_partage) {
    memset(d, 0, sizeof(*d));
    return;
  }
  verrou_prendre(&g_partage->verrou_demande);
  *d = g_partage->demande_audio;
  verrou_rendre(&g_partage->verrou_demande);
}

static void fermer_audio_cumuler(void) {
  if (g_audio) {
    g_xruns_base += audio_xruns(g_audio);
    audio_fermer(g_audio);
    g_audio = NULL;
  }
}

static int ouvrir_audio_cfg(const struct demande_audio *d) {
  if (d->taux <= 0 || d->periode <= 0) return 0;
  g_audio = audio_ouvrir(d->peripherique[0] ? d->peripherique : NULL, d->taux, 2,
                         d->periode, 3);
  return g_audio != NULL;
}

static void erreur_audio(const struct demande_audio *d) {
  const char *detail = audio_derniere_erreur();
  snprintf(g_audio_erreur, sizeof(g_audio_erreur),
           "périphérique %s : %s",
           d->peripherique[0] ? d->peripherique : "par défaut",
           (detail && detail[0]) ? detail : "ouverture impossible");
}

struct sauvegarde_moteur {
  char *json;
  float volume, reverb;
  float gains[MAX_DIVISIONS];
  int ndiv;
  int qualite[4];
  int limiteur, tete;
  int temperament;
};

static void capturer_moteur(struct sauvegarde_moteur *s) {
  memset(s, 0, sizeof(*s));
  // Une combinaison n'est mémorisée qu'en la quittant : capture explicite
  // avant de sérialiser.
  aeolus_capturer_etape(g_moteur);
  s->json = aeolus_sauvegarder(g_moteur);
  s->volume = aeolus_lire_volume(g_moteur);
  s->reverb = aeolus_lire_reverb(g_moteur);
  s->ndiv = aeolus_nb_divisions(g_moteur);
  if (s->ndiv > MAX_DIVISIONS) s->ndiv = MAX_DIVISIONS;
  for (int d = 0; d < s->ndiv; ++d) s->gains[d] = aeolus_lire_gain(g_moteur, d);
  for (int q = 0; q < 4; ++q) s->qualite[q] = aeolus_lire_qualite(g_moteur, q);
  s->limiteur = aeolus_lire_limiteur(g_moteur);
  s->tete = aeolus_lire_reverb_tete(g_moteur);
  s->temperament = aeolus_lire_temperament(g_moteur);
}

static void appliquer_sauvegarde(void *moteur, struct sauvegarde_moteur *s) {
  if (s->json) aeolus_restaurer(moteur, s->json);
  aeolus_volume(moteur, s->volume);
  aeolus_reverb(moteur, s->reverb);
  for (int d = 0; d < s->ndiv; ++d) aeolus_gain(moteur, d, s->gains[d]);
  for (int q = 0; q < 4; ++q) aeolus_qualite(moteur, q, s->qualite[q]);
  aeolus_limiteur(moteur, s->limiteur);
  aeolus_reverb_tete(moteur, s->tete);
  // La création du moteur a pu basculer sur l'autre jeu de tuyaux, resté à
  // l'accord précédent : réapplique donc explicitement le tempérament.
  aeolus_temperament(moteur, s->temperament);
}

// Recrée le moteur à un nouveau taux externe. Le verrou empêche
// l_sauvegarder (processus principal) de lire un moteur en cours de
// destruction ; il n'est posé que pendant la recréation, jamais à chaque
// tampon. L'ancien moteur n'est détruit qu'après la réussite du nouveau.
static int recreer_moteur(int taux) {
  int ok = 0;
  pthread_mutex_lock(&g_moteur_verrou);
  struct sauvegarde_moteur s;
  capturer_moteur(&s);
  void *nouveau = aeolus_creer(taux);
  if (nouveau) {
    appliquer_sauvegarde(nouveau, &s);
    void *ancien = g_moteur;
    g_moteur = nouveau;
    aeolus_detruire(ancien);
    ok = 1;
  }
  free(s.json);
  pthread_mutex_unlock(&g_moteur_verrou);
  return ok;
}

static long maintenant_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

// Une réouverture peut échouer sur EBUSY juste après un fork : un fils né
// à l'instant même du fork peut encore tenir le PCM quelques dizaines de ms.
// Réessayer un peu, sans dépasser la limite globale demandée.
static int ouvrir_audio_attente(const struct demande_audio *d, long limite_ms) {
  for (;;) {
    if (ouvrir_audio_cfg(d)) return 1;
    const char *detail = audio_derniere_erreur();
    int occupe = detail && (strstr(detail, "busy") || strstr(detail, "EBUSY"));
    if (!occupe || maintenant_ms() >= limite_ms) return 0;
    struct timespec pause = {0, 50 * 1000 * 1000};
    nanosleep(&pause, NULL);
  }
}

// Applique une demande : ferme, ouvre la nouvelle sortie, réalloue les
// tampons et recrée le moteur si le taux change. En cas d'échec, rouvre
// l'ancienne configuration ; si elle ne s'ouvre pas non plus, la demande
// reste en attente et sera réessayée par la boucle.
static int appliquer_demande(struct demande_audio *dem, float **bg,
                             float **bd, float **be) {
  // Rien à changer : la configuration demandée est déjà effective. On
  // efface seulement une erreur précédente (elle est résolue).
  if (g_audio && dem->taux == g_taux && dem->periode == g_periode &&
      strcmp(dem->peripherique, g_peripherique) == 0) {
    g_audio_erreur[0] = '\0';
    g_demande_pendante_valide = 0;
    return 1;
  }
  long limite = maintenant_ms() + 500;
  int ancien_taux = g_taux, ancien_periode = g_periode;
  char ancien_periph[PERIPH_MAX + 1];
  strlcpy(ancien_periph, g_peripherique, sizeof(ancien_periph));
  int etait_ouvert = g_audio != NULL;

  if (etait_ouvert) fermer_audio_cumuler();

  if (!ouvrir_audio_attente(dem, limite)) {
    struct demande_audio echec = *dem;
    erreur_audio(&echec);
    struct demande_audio ancienne = {ancien_taux, ancien_periode, {0}};
    strlcpy(ancienne.peripherique, ancien_periph, sizeof(ancienne.peripherique));
    if (!ouvrir_audio_attente(&ancienne, limite)) {
      g_demande_pendante = *dem;
      g_demande_pendante_valide = 1;
    }
    return 0;
  }

  // Nouvelle sortie ouverte : préparer les tampons avant de toucher au
  // moteur, pour pouvoir revenir en arrière sans état à moitié changé.
  float *ng = *bg, *nd = *bd, *ne = *be;
  int nouveaux_tampons = dem->periode != ancien_periode;
  if (nouveaux_tampons) {
    ng = malloc((size_t)dem->periode * sizeof(float));
    nd = malloc((size_t)dem->periode * sizeof(float));
    ne = malloc((size_t)dem->periode * 2 * sizeof(float));
    if (!ng || !nd || !ne) {
      free(ng); free(nd); free(ne);
      struct demande_audio ancienne = {ancien_taux, ancien_periode, {0}};
      strlcpy(ancienne.peripherique, ancien_periph, sizeof(ancienne.peripherique));
      fermer_audio_cumuler();
      if (!ouvrir_audio_cfg(&ancienne)) {
        g_demande_pendante = *dem;
        g_demande_pendante_valide = 1;
      }
      snprintf(g_audio_erreur, sizeof(g_audio_erreur),
               "mémoire insuffisante pour la période %d", dem->periode);
      return 0;
    }
  }

  if (dem->taux != ancien_taux && !recreer_moteur(dem->taux)) {
    if (nouveaux_tampons) { free(ng); free(nd); free(ne); }
    struct demande_audio ancienne = {ancien_taux, ancien_periode, {0}};
    strlcpy(ancienne.peripherique, ancien_periph, sizeof(ancienne.peripherique));
    fermer_audio_cumuler();
    if (!ouvrir_audio_cfg(&ancienne)) {
      g_demande_pendante = *dem;
      g_demande_pendante_valide = 1;
    }
    snprintf(g_audio_erreur, sizeof(g_audio_erreur),
             "recréation du moteur impossible au taux %d", dem->taux);
    return 0;
  }

  if (nouveaux_tampons) {
    free(*bg); free(*bd); free(*be);
    *bg = ng; *bd = nd; *be = ne;
  }
  g_taux = dem->taux;
  g_periode = dem->periode;
  strlcpy(g_peripherique, dem->peripherique, sizeof(g_peripherique));
  g_audio_erreur[0] = '\0';
  g_demande_pendante_valide = 0;
  return 1;
}

static void *boucle_audio(void *arg) {
  // Sous la priorité du fil de PipeWire (88) : il doit pouvoir nous
  // interrompre pour livrer le son. Il faut un droit « rtprio » (groupe
  // pipewire ou audio selon les systèmes) ; sinon on reste en temps partagé.
  struct sched_param sp = {.sched_priority = 70};
  int err = pthread_setschedparam(pthread_self(), SCHED_FIFO, &sp);
  g_etat->temps_reel = err == 0;
  if (err != 0 && IsLinux())
    // Une seule fois, au démarrage du fil : sans droit rtprio (limite PAM,
    // ulimit -r), on reste en temps partagé et le son peut hachurer. Ailleurs
    // (Windows, XNU), cosmocc renvoie ENOSYS et le message n'aurait pas de sens.
    fprintf(stderr,
            "organum : priorité temps réel SCHED_FIFO 70 refusée : %s ; "
            "droit rtprio manquant ? voir /etc/security/limits.d "
            "(groupe audio/pipewire), ou lancer avec « sudo chrt -f 70 ».\n",
            strerror(err));

  float *g = malloc(g_periode * sizeof(float));
  float *d = malloc(g_periode * sizeof(float));
  float *entrelace = malloc(g_periode * 2 * sizeof(float));
  midi_msg_t msgs[64];
  struct commande cmds[32];
  int tours = 0;
  // Première moyenne à une seconde pleine : la seconde en cours au démarrage
  // est partielle et ne compte pas.
  g_mesure_prochaine_seconde = g_taux;

  for (;;) {
    int n;
    while ((n = midi_lire(g_midi, msgs, 64)) > 0)
      for (int i = 0; i < n; ++i) {
        unsigned char m[3] = {msgs[i].statut, msgs[i].d1, msgs[i].d2};
        // Message de canal : marque le canal actif 250 ms, avant les
        // associations pour qu'un CC consommé compte aussi.
        if ((m[0] & 0xF0) < 0xF0) {
          int canal = m[0] & 0x0F;
          g_echeances[canal] = g_echantillons + (unsigned long long)(g_taux * 250 + 999) / 1000;
        }
        if ((m[0] & 0xF0) == 0xB0 && associer(m[0], m[1], m[2])) continue;
        aeolus_midi(g_moteur, m, 3);
      }
    ssize_t lu;
    while ((lu = read(g_tube[0], cmds, sizeof(cmds))) > 0)
      for (size_t i = 0; i < lu / sizeof(struct commande); ++i) {
        if (cmds[i].type == CMD_RECONFIG) {
          struct demande_audio dem;
          copier_demande(&dem);
          appliquer_demande(&dem, &g, &d, &entrelace);
          // Nouveau réglage audio : la pointe repart de zéro et les xruns des
          // trois secondes qui suivent (dont ceux de l'ouverture) sont ignorés.
          mesure_reinitialiser();
          g_xruns_blocage =
              g_echantillons + (unsigned long long)g_taux * XRUNS_BLOCAGE_SECONDES;
          // Fin de la demande, succès comme échec : le message « Application… »
          // s'éteint et audio_erreur prend le relais si besoin. Les réessais
          // automatiques (plus bas) ne comptent pas comme de nouvelles demandes.
          atomic_fetch_add_explicit(&g_partage->traitees_audio, 1,
                                    memory_order_acq_rel);
          atomic_fetch_add_explicit(&g_etat->seq, 1, memory_order_release);
        } else {
          appliquer(&cmds[i]);
        }
      }

    if (!g_audio) {
      // Sortie fermée après un échec : réessai espacé, sans rendre ni
      // quitter le processus, jusqu'à réussite ou nouvelle demande.
      long t = maintenant_ms();
      if (t - g_dernier_essai_audio >= 1000) {
        g_dernier_essai_audio = t;
        struct demande_audio dem;
        if (g_demande_pendante_valide) {
          dem = g_demande_pendante;
        } else {
          dem.taux = g_taux;
          dem.periode = g_periode;
          strlcpy(dem.peripherique, g_peripherique, sizeof(dem.peripherique));
        }
        appliquer_demande(&dem, &g, &d, &entrelace);
        mesure_reinitialiser();
        g_xruns_blocage =
            g_echantillons + (unsigned long long)g_taux * XRUNS_BLOCAGE_SECONDES;
      }
      if (!g_audio) {
        struct timespec pause = {0, 20 * 1000 * 1000};
        nanosleep(&pause, NULL);
        if (++tours % 4 == 0) publier();
        continue;
      }
    }

    // Deux lectures d'horloge par tampon, autour du seul rendu : l'attente
    // d'écriture audio n'entre pas dans la charge. Sous Linux, cosmopolitan
    // passe par __vdso_clock_gettime : aucun appel système.
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    aeolus_rendre(g_moteur, g, d, g_periode);
    clock_gettime(CLOCK_MONOTONIC, &t1);
    for (int i = 0; i < g_periode; ++i) {
      entrelace[2 * i] = g[i];
      entrelace[2 * i + 1] = d[i];
    }
    if (audio_ecrire(g_audio, entrelace, g_periode) < 0) ++g_erreurs_ecriture;
    g_echantillons += g_periode;

    // Charge du tampon, en pourcentage entier de la durée de période.
    long long duree_ns = (t1.tv_sec - t0.tv_sec) * 1000000000LL +
                         (t1.tv_nsec - t0.tv_nsec);
    unsigned long long periode_ns =
        (unsigned long long)g_periode * 1000000000ULL / (unsigned)g_taux;
    unsigned pct = periode_ns && duree_ns > 0
                       ? (unsigned)((unsigned long long)duree_ns * 100 /
                                    periode_ns)
                       : 0;
    g_mesure_somme += pct;
    ++g_mesure_tampons_seconde;
    // Moyenne et évaluation seulement quand des voix sonnent. Les deux
    // additions sont dans cette branche, déjà présente : aucun coût ajouté
    // par tampon hors jeu.
    if (aeolus_nb_voix(g_moteur) > 0) {
      g_mesure_somme_jeu += pct;
      ++g_mesure_tampons_jeu;
      g_mesure_echantillons_joues += g_periode;
      if (g_mesure_echantillons_joues >= (unsigned long long)g_taux)
        g_mesure_evaluee = 1;
    }

    // Xruns récents : on ignore ceux qui arrivent pendant l'application ou
    // dans les trois secondes qui suivent une reconfiguration ou une bascule de tête.
    int total_xruns = g_xruns_base + (g_audio ? audio_xruns(g_audio) : 0);
    int delta_xruns = total_xruns - g_xruns_vus;
    g_xruns_vus = total_xruns;
    if (delta_xruns > 0 &&
        atomic_load_explicit(&g_partage->demandes_audio, memory_order_acquire) ==
            atomic_load_explicit(&g_partage->traitees_audio,
                                 memory_order_acquire) &&
        g_echantillons >= g_xruns_blocage) {
      unsigned ajout = delta_xruns > 65535 ? 65535 : (unsigned)delta_xruns;
      g_xruns_anneau[g_xruns_anneau_pos] += ajout;
      g_xruns_recents += (int)ajout;
    }

    // Une fois par seconde au plus : niveau (comparaison entière) et
    // publication des pourcentages sans toucher à seq.
    if (g_echantillons >= g_mesure_prochaine_seconde) {
      g_mesure_prochaine_seconde = g_echantillons + (unsigned long long)g_taux;
      g_xruns_anneau_pos = (g_xruns_anneau_pos + 1) % XRUNS_ANNEAU;
      g_xruns_recents -= g_xruns_anneau[g_xruns_anneau_pos];
      g_xruns_anneau[g_xruns_anneau_pos] = 0;
      if (g_xruns_recents < 0) g_xruns_recents = 0;
      // Seconde pleine écoulée : sa moyenne rejoint l'anneau, puis la pointe
      // est le maximum des 60 dernières (arithmétique entière). Une seconde
      // sans voix vaut 0 et fait redescendre l'anneau.
      g_mesure_moyennes[g_mesure_moyennes_pos] =
          g_mesure_tampons_jeu
              ? g_mesure_somme_jeu / g_mesure_tampons_jeu
              : 0;
      g_mesure_moyennes_pos =
          (g_mesure_moyennes_pos + 1) % MESURE_MOYENNES;
      g_mesure_pointe = 0;
      for (int i = 0; i < MESURE_MOYENNES; ++i)
        if (g_mesure_moyennes[i] > g_mesure_pointe)
          g_mesure_pointe = g_mesure_moyennes[i];
      g_mesure_somme_jeu = 0;
      g_mesure_tampons_jeu = 0;
      g_etat->charge = g_mesure_tampons_seconde
                           ? (int)(g_mesure_somme / g_mesure_tampons_seconde)
                           : 0;
      g_etat->charge_pointe = (int)g_mesure_pointe;
      g_etat->charge_evaluee = g_mesure_evaluee;
      g_etat->xruns_recents = g_xruns_recents;
      int niveau = calculer_charge_niveau((int)g_mesure_pointe,
                                          g_xruns_recents, g_mesure_evaluee);
      if (niveau != g_etat->charge_niveau) {
        g_etat->charge_niveau = niveau;
        atomic_fetch_add_explicit(&g_etat->seq, 1, memory_order_release);
      }
      g_mesure_somme = 0;
      g_mesure_tampons_seconde = 0;
    }

    if (++tours % 4 == 0) publier();  // ~40 ms à 512 trames
  }
  return arg;
}

static void envoyer(lua_State *L, struct commande c);

// Noms des réglages de qualité, dans l'ordre des champs de l'API C.
static const char *const kNomsQualite[4] = {
    "bruit_attaque", "instabilite", "spatialisation", "polyphonie_max"};

static int champ_qualite(const char *nom) {
  for (int i = 0; i < 4; ++i)
    if (!strcmp(nom, kNomsQualite[i])) return i;
  return -1;
}

// Applique les champs présents de la table de qualité au sommet de la pile.
static void appliquer_qualite_table(lua_State *L, int index) {
  for (int i = 0; i < 4; ++i) {
    lua_getfield(L, index, kNomsQualite[i]);
    if (!lua_isnil(L, -1)) {
      int v;
      if (i < 2)
        v = lua_isboolean(L, -1) ? lua_toboolean(L, -1) : (int)lua_tointeger(L, -1);
      else
        v = (int)lua_tointeger(L, -1);
      aeolus_qualite(g_moteur, i, v);
    }
    lua_pop(L, 1);
  }
}

// organum.qualite(champ, valeur) : champ = nom (voir kNomsQualite) ou entier
// 0..3 ; valeur entière, ou booléen pour les deux premiers champs.
static int l_qualite(lua_State *L) {
  int champ;
  if (lua_type(L, 1) == LUA_TNUMBER) {
    champ = (int)luaL_checkinteger(L, 1);
    if (champ < 0 || champ > 3)
      return luaL_error(L, "champ de qualité hors bornes (0..3)");
  } else {
    const char *nom = luaL_checkstring(L, 1);
    champ = champ_qualite(nom);
    if (champ < 0)
      return luaL_error(L, "champ de qualité inconnu : %s", nom);
  }
  int valeur;
  if (champ < 2 && lua_isboolean(L, 2))
    valeur = lua_toboolean(L, 2);
  else
    valeur = (int)luaL_checkinteger(L, 2);
  envoyer(L, (struct commande){CMD_QUALITE, .a = champ,
                               .masque = (unsigned short)valeur});
  return 0;
}

// organum.calibrer{taux=48000, periode=512} → table de calibration, ou nil,
// erreur. Le micro-banc ne crée aucune instance du moteur : à appeler AVANT
// organum.demarrer (la calibration ne dépend pas du moteur déjà créé).
static int l_calibrer(lua_State *L) {
  int taux = 48000, periode = 512;
  if (lua_istable(L, 1)) {
    lua_getfield(L, 1, "taux");
    if (lua_isinteger(L, -1)) taux = (int)lua_tointeger(L, -1);
    lua_getfield(L, 1, "periode");
    if (lua_isinteger(L, -1)) periode = (int)lua_tointeger(L, -1);
    lua_pop(L, 2);
  }
  if (taux <= 0 || periode <= 0) {
    lua_pushnil(L);
    lua_pushstring(L, "calibration : taux ou période invalide");
    return 2;
  }
  aeolus_calibrage c;
  memset(&c, 0, sizeof(c));
  aeolus_calibrer(taux, periode, &c);
  lua_createtable(L, 0, 11);
  lua_pushinteger(L, c.niveau), lua_setfield(L, -2, "niveau");
  lua_pushboolean(L, c.tete_reverb), lua_setfield(L, -2, "tete_reverb");
  lua_pushnumber(L, c.echeance_ms), lua_setfield(L, -2, "echeance_ms");
  lua_createtable(L, 4, 0);
  for (int i = 0; i < 4; ++i) {
    lua_pushnumber(L, c.estimation_ms[i]);
    lua_rawseti(L, -2, i + 1);
  }
  lua_setfield(L, -2, "estimation_ms");
  lua_pushnumber(L, c.cout_spat2_us), lua_setfield(L, -2, "cout_spat2_us");
  lua_pushnumber(L, c.cout_spat1_us), lua_setfield(L, -2, "cout_spat1_us");
  lua_pushnumber(L, c.cout_reverb_tete_ms);
  lua_setfield(L, -2, "cout_reverb_tete_ms");
  lua_pushnumber(L, c.cout_reverb_sans_tete_ms);
  lua_setfield(L, -2, "cout_reverb_sans_tete_ms");
  lua_pushinteger(L, c.voix_ref), lua_setfield(L, -2, "voix_ref");
  lua_pushnumber(L, c.duree_calibration_ms);
  lua_setfield(L, -2, "duree_calibration_ms");
  return 1;
}

// organum.demarrer{taux=48000, periode=512, peripherique="default",
//                  limiteur=true, jeux={{division, jeu}, …},
//                  qualite={bruit_attaque=…, …}, tete_reverb=true}
//                  → true | nil, erreur
static int l_demarrer(lua_State *L) {
  if (g_etat) return luaL_error(L, "organum déjà démarré");
  g_maitre = getpid();
  int taux = 48000, nb_periodes = 3, limiteur = 1;
  const char *peripherique = NULL;
  g_periode = 512;
  g_taux = 48000;
  if (lua_istable(L, 1)) {
    lua_getfield(L, 1, "taux");
    if (lua_isinteger(L, -1)) taux = lua_tointeger(L, -1);
    lua_getfield(L, 1, "periode");
    if (lua_isinteger(L, -1)) g_periode = lua_tointeger(L, -1);
    lua_getfield(L, 1, "peripherique");
    if (lua_isstring(L, -1)) peripherique = lua_tostring(L, -1);
    lua_getfield(L, 1, "limiteur");
    if (!lua_isnil(L, -1)) limiteur = lua_toboolean(L, -1);
    lua_pop(L, 4);
  }

  g_partage = mmap(NULL, sizeof(struct etat_partage), PROT_READ | PROT_WRITE,
                   MAP_SHARED | MAP_ANONYMOUS, -1, 0);
  if (g_partage == MAP_FAILED) {
    g_partage = NULL;
    g_etat = NULL;
    lua_pushnil(L);
    lua_pushstring(L, "mémoire partagée indisponible");
    return 2;
  }
  memset(g_partage, 0, sizeof(*g_partage));
  g_etat = &g_partage->etat;
  atomic_init(&g_partage->verrou_demande, 0);
  atomic_init(&g_partage->demandes_audio, 0);
  atomic_init(&g_partage->traitees_audio, 0);
  atomic_init(&g_partage->verrou_temperament, 0);
  atomic_init(&g_partage->demandes_temperament, 0);
  atomic_init(&g_partage->traitees_temperament, 0);
  atomic_init(&g_partage->temperament_demande, -1);
  mesure_init();
  if (pipe(g_tube) < 0) {
    liberer_demarrage();
    lua_pushnil(L);
    lua_pushstring(L, strerror(errno));
    return 2;
  }
  fcntl(g_tube[0], F_SETFL, O_NONBLOCK);

  g_moteur = aeolus_creer(taux);
  g_limiteur = limiteur;
  g_taux = taux;
  g_xruns_base = 0;
  g_audio_erreur[0] = '\0';
  g_demande_pendante_valide = 0;
  strlcpy(g_peripherique, peripherique ? peripherique : "",
          sizeof(g_peripherique));
  // Le limiteur est actif par défaut dans aeolus_creer ; l'option ne sert
  // qu'à le couper (mesure, diagnostic).
  aeolus_limiteur(g_moteur, limiteur);
  // Réglages de qualité appliqués avant l'ouverture audio, donc actifs dès
  // la première voix.
  if (lua_istable(L, 1)) {
    lua_getfield(L, 1, "qualite");
    if (lua_istable(L, -1)) appliquer_qualite_table(L, lua_gettop(L));
    lua_pop(L, 1);
  }
  // Tempérament initial : appliqué avant l'ouverture audio, donc audible dès
  // la première note. Hors bornes ou absent : égal (préserve les fichiers
  // existants et neutralise tout réglage utilisateur d'Aeolus).
  {
    int temperament = 5;  // Scale::EqualTemp
    int ntemperaments = aeolus_nb_temperaments();
    if (lua_istable(L, 1)) {
      lua_getfield(L, 1, "temperament");
      if (lua_isinteger(L, -1)) {
        lua_Integer v = lua_tointeger(L, -1);
        if (v >= 0 && v < ntemperaments) temperament = (int)v;
      }
      lua_pop(L, 1);
    }
    // Ne reconstruire les jeux que si la valeur demandée diffère de celle
    // que loadRankwaves a déjà construite (l'égal par défaut, ou le réglage
    // lu dans le fichier utilisateur d'Aeolus s'il existe). La comparaison
    // porte sur l'effectif, pas sur la constante de l'enum.
    int effectif = aeolus_lire_temperament(g_moteur);
    if (effectif != temperament) {
      aeolus_temperament(g_moteur, temperament);
      effectif = aeolus_lire_temperament(g_moteur);
    }
    g_etat->temperament = effectif;
  }
  // Tête de convolution zéro latence de la réverbération : active par
  // défaut ; l'option tete_reverb=false la coupe, et ORGANUM_REVERB_TETE
  // reste prioritaire (=non ou 0 coupe, sinon comportement par défaut).
  {
    int tete = 1;
    int impose = 0;
    if (lua_istable(L, 1)) {
      lua_getfield(L, 1, "tete_reverb");
      if (!lua_isnil(L, -1)) tete = lua_toboolean(L, -1);
      lua_pop(L, 1);
    }
    const char *env = getenv("ORGANUM_REVERB_TETE");
    if (env && (!strcmp(env, "non") || !strcmp(env, "0")))
      tete = 0, impose = 1;
    else if (env && (!strcmp(env, "oui") || !strcmp(env, "1")))
      tete = 1, impose = 1;
    aeolus_reverb_tete(g_moteur, tete);
    // Valeur effective publiée dès le démarrage, avant le premier battement
    // du fil audio : l'interface ne doit jamais annoncer la valeur demandée
    // quand l'environnement la force.
    g_etat->tete_reverb = aeolus_lire_reverb_tete(g_moteur);
    g_etat->tete_reverb_impose = impose;
  }
  // Ne pas tenter de borner audio_ouvrir() par SIGALRM : cosmo_dlopen fait
  // passer les appels dans libasound par un trampoline qui bloque tous les
  // signaux, y compris SIGALRM. Un serveur audio figé peut donc encore
  // bloquer cette ouverture ; le chemin hw:C,D, lui, ouvre en O_NONBLOCK.
  if (!(g_audio = audio_ouvrir(peripherique, taux, 2, g_periode, nb_periodes))) {
    const char *detail = audio_derniere_erreur();
    char message[1200];
    if (detail && detail[0])
      snprintf(message, sizeof(message), "sortie audio indisponible : %s", detail);
    else
      snprintf(message, sizeof(message), "sortie audio indisponible");
    liberer_demarrage();
    lua_pushnil(L);
    lua_pushstring(L, message);
    return 2;
  }
  if (!(g_midi = midi_ouvrir("Organum", "entree"))) {
    liberer_demarrage();
    lua_pushnil(L);
    lua_pushstring(L, "séquenceur MIDI indisponible");
    return 2;
  }

  int automatique = 1;
  if (lua_istable(L, 1)) {
    lua_getfield(L, 1, "connexion_automatique");
    if (!lua_isnil(L, -1)) automatique = lua_toboolean(L, -1);
    lua_pop(L, 1);
  }
  if (automatique) midi_connecter_tout(g_midi);

  // État sauvegardé (jeux, accouplements, combinaisons), avant le fil audio.
  if (lua_istable(L, 1)) {
    lua_getfield(L, 1, "etat");
    if (lua_isstring(L, -1) && aeolus_restaurer(g_moteur, lua_tostring(L, -1)))
      fprintf(stderr, "organum : état sauvegardé illisible, ignoré\n");
    lua_pop(L, 1);
  }

  struct etat *e = g_etat;
  g_taux = taux;
  e->taux = taux;
  e->periode = g_periode;
  e->nb_periodes = nb_periodes;
  e->limiteur = limiteur;
  strlcpy(e->peripherique, g_peripherique, sizeof(e->peripherique));
  e->netapes = aeolus_nb_etapes(g_moteur);
  midi_adresse(g_midi, &e->midi_client, &e->midi_port);
  e->ndivisions = aeolus_nb_divisions(g_moteur);
  if (e->ndivisions > MAX_DIVISIONS) e->ndivisions = MAX_DIVISIONS;
  for (int d = 0; d < e->ndivisions; ++d) {
    copier_nom(e->divisions[d].nom, aeolus_nom_division(g_moteur, d));
    int n = aeolus_nb_jeux(g_moteur, d);
    e->divisions[d].njeux = n > MAX_JEUX ? MAX_JEUX : n;
    for (int j = 0; j < e->divisions[d].njeux; ++j)
      copier_nom(e->divisions[d].jeux[j].nom, aeolus_nom_jeu(g_moteur, d, j));
    n = aeolus_nb_liens(g_moteur, d);
    e->divisions[d].nliens = n > MAX_LIENS ? MAX_LIENS : n;
    for (int l = 0; l < e->divisions[d].nliens; ++l)
      e->divisions[d].liens[l].division = aeolus_division_liee(g_moteur, d, l);
  }

  if (lua_istable(L, 1)) {
    lua_getfield(L, 1, "jeux");
    if (lua_istable(L, -1))
      for (lua_Integer i = 1; lua_rawgeti(L, -1, i) == LUA_TTABLE; ++i) {
        lua_rawgeti(L, -1, 1);
        lua_rawgeti(L, -2, 2);
        aeolus_jeu(g_moteur, lua_tointeger(L, -2) - 1, lua_tointeger(L, -1) - 1, 1);
        lua_pop(L, 3);
      }
    lua_pop(L, 2);
  }
  publier();

  demarrer_fil_temperament();

  pthread_t fil;
  if (pthread_create(&fil, NULL, boucle_audio, NULL)) {
    liberer_demarrage();
    lua_pushnil(L);
    lua_pushstring(L, "fil audio impossible");
    return 2;
  }
  pthread_detach(fil);
  lua_pushboolean(L, 1);
  return 1;
}

// organum.limiteur(actif) : applique à chaud, dans le fil audio.
static int l_limiteur(lua_State *L) {
  envoyer(L, (struct commande){CMD_LIMITEUR, .a = lua_toboolean(L, 1) ? 1 : 0});
  return 0;
}

// organum.tete_reverb(actif) : applique à chaud, sauf ORGANUM_REVERB_TETE.
static int l_tete_reverb(lua_State *L) {
  envoyer(L, (struct commande){CMD_TETE, .a = lua_toboolean(L, 1) ? 1 : 0});
  return 0;
}

// organum.temperament(type) : demande un changement de tempérament (0..10,
// voir aeolus_nb_temperaments). Le calcul se fait hors du fil audio, qui
// continue de rendre le jeu courant ; seule la dernière demande déposée
// compte réellement à la fin. Les demandes rapprochées restent comptées
// jusqu'au calcul qui les couvre (qualite.application).
static int l_temperament(lua_State *L) {
  if (!g_etat || !g_partage)
    return luaL_error(L, "organum non démarré (organum.demarrer dans .init.lua)");
  int type = (int)luaL_checkinteger(L, 1);
  int n = aeolus_nb_temperaments();
  if (type < 0 || type >= n)
    return luaL_error(L, "tempérament hors bornes (0..%d)", n - 1);
  verrou_prendre(&g_partage->verrou_temperament);
  atomic_store_explicit(&g_partage->temperament_demande, type,
                        memory_order_release);
  atomic_fetch_add_explicit(&g_partage->demandes_temperament, 1,
                            memory_order_acq_rel);
  verrou_rendre(&g_partage->verrou_temperament);
  atomic_fetch_add_explicit(&g_etat->seq, 1, memory_order_release);
  return 0;
}

// organum.oublier_audio() : à appeler dans un fils après fork. Ferme les
// descripteurs PCM hérités et oublie leurs mappages, sans toucher au flux du
// parent (aucun appel ALSA).
static int l_oublier_audio(lua_State *L) {
  oublier_audio_fils();
  lua_pushboolean(L, 1);
  return 1;
}

// organum.reconfigurer_audio{taux=, periode=, peripherique=} : dépose la
// demande complète dans le mmap partagé, puis réveille le fil audio par le
// tube. Le nom du périphérique ne tient pas dans struct commande.
static int l_reconfigurer_audio(lua_State *L) {
  if (!g_etat || !g_partage)
    return luaL_error(L, "organum non démarré (organum.demarrer dans .init.lua)");
  struct demande_audio d;
  memset(&d, 0, sizeof(d));
  d.taux = g_etat->taux;
  d.periode = g_etat->periode;
  strlcpy(d.peripherique, g_etat->peripherique, sizeof(d.peripherique));
  if (lua_istable(L, 1)) {
    lua_getfield(L, 1, "taux");
    if (lua_isinteger(L, -1)) d.taux = (int)lua_tointeger(L, -1);
    lua_getfield(L, 1, "periode");
    if (lua_isinteger(L, -1)) d.periode = (int)lua_tointeger(L, -1);
    lua_getfield(L, 1, "peripherique");
    if (lua_isstring(L, -1))
      strlcpy(d.peripherique, lua_tostring(L, -1), sizeof(d.peripherique));
    lua_pop(L, 3);
  }
  if (d.taux <= 0 || d.periode <= 0)
    return luaL_error(L, "reconfigurer_audio : taux ou période invalide");
  verrou_prendre(&g_partage->verrou_demande);
  g_partage->demande_audio = d;
  verrou_rendre(&g_partage->verrou_demande);
  // Compteur incrémenté AVANT l'envoi : le fil audio peut traiter la commande
  // très vite, il ne doit jamais publier « traité » avant « demandé ».
  // Le numéro de séquence change aussi au début pour réveiller attendre.
  atomic_fetch_add_explicit(&g_partage->demandes_audio, 1, memory_order_acq_rel);
  atomic_fetch_add_explicit(&g_etat->seq, 1, memory_order_release);
  struct commande c = {CMD_RECONFIG};
  if (write(g_tube[1], &c, sizeof(c)) != sizeof(c)) {
    int sauve = errno;
    // Commande non envoyée : rembobiner demandes, mais ne jamais faire
    // reculer seq (un numéro déjà vu pourrait manquer un changement) :
    // on l'incrémente de nouveau après le rembobinage.
    atomic_fetch_sub_explicit(&g_partage->demandes_audio, 1, memory_order_acq_rel);
    atomic_fetch_add_explicit(&g_etat->seq, 1, memory_order_release);
    return luaL_error(L, "commande perdue : %s", strerror(sauve));
  }
  return 0;
}

static struct etat *etat_ou_erreur(lua_State *L) {
  if (!g_etat) luaL_error(L, "organum non démarré (organum.demarrer dans .init.lua)");
  return g_etat;
}

static void envoyer(lua_State *L, struct commande c) {
  etat_ou_erreur(L);
  if (write(g_tube[1], &c, sizeof(c)) != sizeof(c))
    luaL_error(L, "commande perdue : %s", strerror(errno));
}

// organum.etat() → {seq, volume, reverb, xruns, taux, periode, nb_periodes,
//                   erreurs_ecriture, temps_reel, midi="c:p",
//                   canaux_controle, canaux_expression, canaux_actifs,
//                   qualite={bruit_attaque, instabilite, spatialisation,
//                            polyphonie_max, tete_reverb (effectif),
//                            tete_reverb_impose, peripherique (effectif,
//                            "" = défaut), limiteur (effectif),
//                            audio_erreur (dernier échec de reconfiguration)},
//                   divisions={{nom, gain, jeux={{nom, actif}, …}}, …}}
// canaux_actifs est éphémère (activité des 250 dernières ms) et hors de seq.
static int l_etat(lua_State *L) {
  struct etat *e = etat_ou_erreur(L);
  struct etat copie;
  // Copie cohérente : on recommence si le fil audio a publié entre-temps.
  unsigned seq;
  do {
    seq = atomic_load_explicit(&e->seq, memory_order_acquire);
    memcpy(&copie, e, sizeof(copie));
  } while (seq != atomic_load_explicit(&e->seq, memory_order_acquire));
  // Activité MIDI : chargée à part, elle ne participe pas à seq.
  unsigned canaux_actifs =
      atomic_load_explicit(&g_partage->canaux_actifs, memory_order_relaxed);
  // Compteurs de reconfiguration, lus atomiquement (comme seq, ils ne sont
  // pas pris dans la copie cohérente).
  unsigned demandes_audio =
      atomic_load_explicit(&g_partage->demandes_audio, memory_order_acquire);
  unsigned traitees_audio =
      atomic_load_explicit(&g_partage->traitees_audio, memory_order_acquire);
  unsigned demandes_temperament =
      atomic_load_explicit(&g_partage->demandes_temperament, memory_order_acquire);
  unsigned traitees_temperament =
      atomic_load_explicit(&g_partage->traitees_temperament, memory_order_acquire);

  lua_createtable(L, 0, 7);
  lua_pushinteger(L, seq), lua_setfield(L, -2, "seq");
  lua_pushnumber(L, copie.volume), lua_setfield(L, -2, "volume");
  lua_pushnumber(L, copie.reverb), lua_setfield(L, -2, "reverb");
  lua_pushinteger(L, copie.xruns), lua_setfield(L, -2, "xruns");
  lua_pushboolean(L, copie.temps_reel), lua_setfield(L, -2, "temps_reel");
  lua_pushinteger(L, copie.periode), lua_setfield(L, -2, "periode");
  lua_pushinteger(L, copie.nb_periodes), lua_setfield(L, -2, "nb_periodes");
  lua_pushinteger(L, copie.erreurs_ecriture), lua_setfield(L, -2, "erreurs_ecriture");
  lua_pushinteger(L, copie.etape), lua_setfield(L, -2, "etape");
  lua_pushinteger(L, copie.netapes), lua_setfield(L, -2, "netapes");
  lua_pushinteger(L, copie.taux), lua_setfield(L, -2, "taux");
  lua_pushinteger(L, copie.temperament);
  lua_setfield(L, -2, "temperament");
  lua_pushfstring(L, "%d:%d", copie.midi_client, copie.midi_port);
  lua_setfield(L, -2, "midi");
  lua_pushinteger(L, copie.canaux_controle), lua_setfield(L, -2, "canaux_controle");
  lua_pushinteger(L, copie.canaux_expression), lua_setfield(L, -2, "canaux_expression");
  lua_pushinteger(L, canaux_actifs), lua_setfield(L, -2, "canaux_actifs");
  lua_createtable(L, 0, 6);
  lua_pushboolean(L, copie.bruit_attaque), lua_setfield(L, -2, "bruit_attaque");
  lua_pushboolean(L, copie.instabilite), lua_setfield(L, -2, "instabilite");
  lua_pushinteger(L, copie.spatialisation), lua_setfield(L, -2, "spatialisation");
  lua_pushinteger(L, copie.polyphonie_max), lua_setfield(L, -2, "polyphonie_max");
  lua_pushboolean(L, copie.tete_reverb), lua_setfield(L, -2, "tete_reverb");
  lua_pushboolean(L, copie.tete_reverb_impose),
      lua_setfield(L, -2, "tete_reverb_impose");
  lua_pushstring(L, copie.peripherique);
  lua_setfield(L, -2, "peripherique");
  lua_pushboolean(L, copie.limiteur);
  lua_setfield(L, -2, "limiteur");
  lua_pushstring(L, copie.audio_erreur);
  lua_setfield(L, -2, "audio_erreur");
  lua_pushinteger(L, copie.temperament);
  lua_setfield(L, -2, "temperament");
  lua_pushstring(L, copie.temperament_erreur);
  lua_setfield(L, -2, "temperament_erreur");
  lua_pushboolean(L, demandes_audio != traitees_audio ||
                         demandes_temperament != traitees_temperament);
  lua_setfield(L, -2, "application");
  lua_pushinteger(L, copie.xruns), lua_setfield(L, -2, "xruns");
  lua_pushinteger(L, copie.xruns_recents);
  lua_setfield(L, -2, "xruns_recents");
  lua_pushinteger(L, copie.charge), lua_setfield(L, -2, "charge");
  lua_pushinteger(L, copie.charge_pointe);
  lua_setfield(L, -2, "charge_pointe");
  lua_pushboolean(L, copie.charge_evaluee);
  lua_setfield(L, -2, "charge_evaluee");
  lua_pushinteger(L, copie.charge_niveau);
  lua_setfield(L, -2, "charge_niveau");
  lua_setfield(L, -2, "qualite");
  lua_createtable(L, copie.nassociations, 0);
  for (int i = 0; i < copie.nassociations; ++i) {
    struct association *a = &copie.associations[i];
    lua_createtable(L, 0, 4);
    if (a->canal != TOUS_CANAUX)
      lua_pushinteger(L, a->canal + 1), lua_setfield(L, -2, "canal");
    lua_pushinteger(L, a->cc), lua_setfield(L, -2, "cc");
    static const char *const kCibles[] = {"aucune", "volume", "reverb", "gain"};
    lua_pushstring(L, kCibles[a->cible < 4 ? a->cible : 0]), lua_setfield(L, -2, "cible");
    if (a->cible == CIBLE_GAIN)
      lua_pushinteger(L, a->division + 1), lua_setfield(L, -2, "division");
    lua_rawseti(L, -2, i + 1);
  }
  lua_setfield(L, -2, "associations");
  if (copie.dernier_cc >= 0) {
    lua_createtable(L, 0, 3);
    lua_pushinteger(L, copie.dernier_canal + 1), lua_setfield(L, -2, "canal");
    lua_pushinteger(L, copie.dernier_cc), lua_setfield(L, -2, "cc");
    lua_pushinteger(L, copie.derniere_valeur), lua_setfield(L, -2, "valeur");
    lua_setfield(L, -2, "dernier_controle");
  }
  lua_createtable(L, copie.ndivisions, 0);
  for (int d = 0; d < copie.ndivisions; ++d) {
    lua_createtable(L, 0, 3);
    lua_pushstring(L, copie.divisions[d].nom), lua_setfield(L, -2, "nom");
    lua_pushnumber(L, copie.divisions[d].gain), lua_setfield(L, -2, "gain");
    lua_pushinteger(L, copie.divisions[d].canaux), lua_setfield(L, -2, "canaux");
    lua_createtable(L, copie.divisions[d].nliens, 0);
    for (int l = 0; l < copie.divisions[d].nliens; ++l) {
      lua_createtable(L, 0, 2);
      lua_pushinteger(L, copie.divisions[d].liens[l].division + 1), lua_setfield(L, -2, "division");
      lua_pushboolean(L, copie.divisions[d].liens[l].actif), lua_setfield(L, -2, "actif");
      lua_rawseti(L, -2, l + 1);
    }
    lua_setfield(L, -2, "liens");
    lua_createtable(L, copie.divisions[d].njeux, 0);
    for (int j = 0; j < copie.divisions[d].njeux; ++j) {
      lua_createtable(L, 0, 2);
      lua_pushstring(L, copie.divisions[d].jeux[j].nom), lua_setfield(L, -2, "nom");
      lua_pushboolean(L, copie.divisions[d].jeux[j].actif), lua_setfield(L, -2, "actif");
      lua_rawseti(L, -2, j + 1);
    }
    lua_setfield(L, -2, "jeux");
    lua_rawseti(L, -2, d + 1);
  }
  lua_setfield(L, -2, "divisions");
  return 1;
}

// organum.attendre(seq, ms) → seq : rend la main dès que l'état diffère de
// seq, ou au bout de ms millisecondes.
static int l_attendre(lua_State *L) {
  struct etat *e = etat_ou_erreur(L);
  unsigned connu = luaL_checkinteger(L, 1);
  lua_Integer ms = luaL_optinteger(L, 2, 25000);
  struct timespec pas = {0, 20 * 1000000};
  unsigned seq;
  for (lua_Integer t = 0;; t += 20) {
    seq = atomic_load_explicit(&e->seq, memory_order_acquire);
    // Le processus principal a disparu : personne ne publiera plus rien.
    if (seq != connu || t >= ms || getppid() != g_maitre) break;
    nanosleep(&pas, NULL);
  }
  lua_pushinteger(L, seq);
  return 1;
}

// Indices Lua : divisions et jeux numérotés à partir de 1.
static int l_jeu(lua_State *L) {
  envoyer(L, (struct commande){CMD_JEU, luaL_checkinteger(L, 1) - 1,
                               luaL_checkinteger(L, 2) - 1, lua_toboolean(L, 3)});
  return 0;
}

static int l_gain(lua_State *L) {
  envoyer(L, (struct commande){CMD_GAIN, luaL_checkinteger(L, 1) - 1,
                               .valeur = luaL_checknumber(L, 2)});
  return 0;
}

static int l_volume(lua_State *L) {
  envoyer(L, (struct commande){CMD_VOLUME, .valeur = luaL_checknumber(L, 1)});
  return 0;
}

static int l_reverb(lua_State *L) {
  envoyer(L, (struct commande){CMD_REVERB, .valeur = luaL_checknumber(L, 1)});
  return 0;
}

static int l_midi(lua_State *L) {
  envoyer(L, (struct commande){CMD_MIDI, luaL_checkinteger(L, 1),
                               luaL_optinteger(L, 2, 0), luaL_optinteger(L, 3, 0)});
  return 0;
}

static int l_panique(lua_State *L) {
  envoyer(L, (struct commande){CMD_PANIQUE});
  return 0;
}

// organum.sauvegarder() → état du moteur en JSON. Seulement dans le
// processus principal (celui qui a démarré le moteur) ; lu pendant que le
// fil audio tourne, comme le faisait l'hôte du greffon.
static int l_sauvegarder(lua_State *L) {
  if (!g_moteur || getpid() != g_maitre)
    return luaL_error(L, "organum.sauvegarder : processus principal seulement");
  pthread_mutex_lock(&g_moteur_verrou);
  char *json = aeolus_sauvegarder(g_moteur);
  pthread_mutex_unlock(&g_moteur_verrou);
  if (!json) return 0;
  lua_pushstring(L, json);
  free(json);
  return 1;
}

// organum.lien(division, lien, actif) : accouplement, indices à partir de 1.
static int l_lien(lua_State *L) {
  envoyer(L, (struct commande){CMD_LIEN, luaL_checkinteger(L, 1) - 1,
                               luaL_checkinteger(L, 2) - 1, lua_toboolean(L, 3)});
  return 0;
}

// Masques de canaux : entier de 16 bits, bit n = canal n+1.
static int l_canaux_division(lua_State *L) {
  envoyer(L, (struct commande){CMD_CANAUX_DIVISION, luaL_checkinteger(L, 1) - 1,
                               .masque = luaL_checkinteger(L, 2)});
  return 0;
}

static int l_canaux_controle(lua_State *L) {
  envoyer(L, (struct commande){CMD_CANAUX_CONTROLE, .masque = luaL_checkinteger(L, 1)});
  return 0;
}

static int l_canaux_expression(lua_State *L) {
  envoyer(L, (struct commande){CMD_CANAUX_EXPRESSION, .masque = luaL_checkinteger(L, 1)});
  return 0;
}

// organum.associations{{canal=1..16|nil, cc=0..127, cible="volume"|"reverb"
//                       |"gain", division=1..}, …} : remplace la liste.
static int l_associations(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  int n = luaL_len(L, 1);
  if (n > MAX_ASSOCIATIONS) return luaL_error(L, "au plus %d associations", MAX_ASSOCIATIONS);
  static const char *const kCibles[] = {"aucune", "volume", "reverb", "gain", NULL};
  struct commande cmds[MAX_ASSOCIATIONS + 1];
  for (int i = 1; i <= n; ++i) {
    lua_rawgeti(L, 1, i);
    luaL_checktype(L, -1, LUA_TTABLE);
    lua_getfield(L, -1, "canal");
    lua_getfield(L, -2, "cc");
    lua_getfield(L, -3, "cible");
    lua_getfield(L, -4, "division");
    lua_Integer canal = luaL_optinteger(L, -4, 0);
    lua_Integer cc = luaL_checkinteger(L, -3);
    int cible = luaL_checkoption(L, -2, "aucune", kCibles);
    lua_Integer division = luaL_optinteger(L, -1, 1);
    if (canal < 0 || canal > 16 || cc < 0 || cc > 127 || division < 1)
      return luaL_error(L, "association %d invalide", i);
    cmds[i - 1] = (struct commande){CMD_ASSOCIATION, i - 1, canal ? canal - 1 : TOUS_CANAUX,
                                    cc, cible, .masque = division - 1};
    lua_pop(L, 5);
  }
  cmds[n] = (struct commande){CMD_NB_ASSOCIATIONS, n};
  for (int i = 0; i <= n; ++i) envoyer(L, cmds[i]);
  return 0;
}

// organum.midi_ports() → liste des ports du séquenceur du système. Chaque
// entrée : {client, port, nom_client, nom_port, source, destination,
// connecte, organum, lecture, ecriture, abonnement, generique, capacites,
// type}. Les
// fonctions MIDI n'utilisent ni le tube ni struct etat : elles parlent
// directement au descripteur ALSA hérité, y compris dans le processus fils
// de la fenêtre native. La liste des adresses déconnectées, elle, est bien
// en mémoire partagée entre ces processus.
static int l_midi_ports(lua_State *L) {
  if (!g_midi) return luaL_error(L, "organum non démarré (organum.demarrer dans .init.lua)");
  struct midi_port *ports = malloc(MIDI_MAX_PORTS * sizeof(*ports));
  if (!ports) return luaL_error(L, "mémoire insuffisante");
  int n = midi_ports(g_midi, ports, MIDI_MAX_PORTS);
  if (n < 0) {
    int err = errno;
    free(ports);
    return luaL_error(L, "ports MIDI indisponibles : %s", strerror(err));
  }
  lua_createtable(L, n, 0);
  for (int i = 0; i < n; ++i) {
    struct midi_port *p = &ports[i];
    lua_createtable(L, 0, 13);
    lua_pushinteger(L, p->client), lua_setfield(L, -2, "client");
    lua_pushinteger(L, p->port), lua_setfield(L, -2, "port");
    lua_pushstring(L, p->nom_client), lua_setfield(L, -2, "nom_client");
    lua_pushstring(L, p->nom_port), lua_setfield(L, -2, "nom_port");
    lua_pushboolean(L, p->source), lua_setfield(L, -2, "source");
    lua_pushboolean(L, p->destination), lua_setfield(L, -2, "destination");
    lua_pushboolean(L, p->connecte), lua_setfield(L, -2, "connecte");
    lua_pushboolean(L, p->organum), lua_setfield(L, -2, "organum");
    lua_pushboolean(L, p->lecture), lua_setfield(L, -2, "lecture");
    lua_pushboolean(L, p->ecriture), lua_setfield(L, -2, "ecriture");
    lua_pushboolean(L, p->abonnement), lua_setfield(L, -2, "abonnement");
    lua_pushboolean(L, p->generique), lua_setfield(L, -2, "generique");
    lua_pushinteger(L, p->capacites), lua_setfield(L, -2, "capacites");
    lua_pushinteger(L, p->type), lua_setfield(L, -2, "type");
    lua_pushfstring(L, "%d:%d", p->client, p->port), lua_setfield(L, -2, "adresse");
    lua_rawseti(L, -2, i + 1);
  }
  free(ports);
  return 1;
}

// Les adresses ALSA tiennent sur un octet : sans borne, 256:0 serait
// tronqué en 0:0 dans le noyau et abonnerait un autre port.
static void verifier_adresse_midi(lua_State *L, lua_Integer client, lua_Integer port) {
  if (client < 0 || client > 255 || port < 0 || port > 255)
    luaL_error(L, "adresse MIDI %I:%I hors bornes (client et port entre 0 et 255)",
               client, port);
}

// organum.midi_connecter(client, port) : abonne une source à notre port.
static int l_midi_connecter(lua_State *L) {
  if (!g_midi) return luaL_error(L, "organum non démarré (organum.demarrer dans .init.lua)");
  lua_Integer client = luaL_checkinteger(L, 1), port = luaL_checkinteger(L, 2);
  verifier_adresse_midi(L, client, port);
  if (midi_connecter(g_midi, (int)client, (int)port) < 0)
    return luaL_error(L, "connexion MIDI %d:%d impossible : %s",
                      (int)client, (int)port, strerror(errno));
  lua_pushboolean(L, 1);
  return 1;
}

// organum.midi_deconnecter(client, port) : désabonne et empêche la
// reconnexion automatique jusqu'au prochain organum.midi_connecter_tout().
static int l_midi_deconnecter(lua_State *L) {
  if (!g_midi) return luaL_error(L, "organum non démarré (organum.demarrer dans .init.lua)");
  lua_Integer client = luaL_checkinteger(L, 1), port = luaL_checkinteger(L, 2);
  verifier_adresse_midi(L, client, port);
  if (client == 0 && port == 1)
    return luaL_error(L, "déconnexion MIDI 0:1 refusée : c'est le port d'annonces "
                         "du système, qui détecte les nouveaux ports");
  if (midi_deconnecter(g_midi, (int)client, (int)port) < 0)
    return luaL_error(L, "déconnexion MIDI %d:%d impossible : %s",
                      (int)client, (int)port, strerror(errno));
  lua_pushboolean(L, 1);
  return 1;
}

// organum.charge_niveau(pointe, xruns_recents, evaluee) → 0..3.
// Point d'entrée de diagnostic pour tester la règle C sans moteur audio.
static int l_charge_niveau_diag(lua_State *L) {
  int pointe = (int)luaL_checkinteger(L, 1);
  int recents = (int)luaL_checkinteger(L, 2);
  int evaluee = lua_toboolean(L, 3);
  lua_pushinteger(L, calculer_charge_niveau(pointe, recents, evaluee));
  return 1;
}

static const luaL_Reg kFonctions[] = {
    {"demarrer", l_demarrer}, {"etat", l_etat},     {"attendre", l_attendre},
    {"jeu", l_jeu},           {"gain", l_gain},     {"volume", l_volume},
    {"reverb", l_reverb},     {"midi", l_midi},     {"panique", l_panique},
    {"qualite", l_qualite}, {"calibrer", l_calibrer},
    {"charge_niveau", l_charge_niveau_diag},
    {"limiteur", l_limiteur}, {"tete_reverb", l_tete_reverb},
    {"temperament", l_temperament},
    {"oublier_audio", l_oublier_audio},
    {"reconfigurer_audio", l_reconfigurer_audio},
    {"canaux_division", l_canaux_division},
    {"canaux_controle", l_canaux_controle},
    {"canaux_expression", l_canaux_expression},
    {"associations", l_associations},
    {"lien", l_lien},
    {"midi_ports", l_midi_ports},
    {"midi_connecter", l_midi_connecter},
    {"midi_deconnecter", l_midi_deconnecter},
    {"sauvegarder", l_sauvegarder},
    {NULL, NULL},
};

int luaopen_organum(lua_State *L) {
  luaL_newlib(L, kFonctions);
  return 1;
}
