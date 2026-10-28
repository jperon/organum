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
#include "libc/dce.h"
#include "third_party/lua/lauxlib.h"
#include "third_party/lua/lua.h"

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

enum {
  CMD_JEU, CMD_GAIN, CMD_VOLUME, CMD_REVERB, CMD_MIDI, CMD_PANIQUE,
  CMD_CANAUX_DIVISION, CMD_CANAUX_CONTROLE, CMD_CANAUX_EXPRESSION,
  CMD_ASSOCIATION, CMD_NB_ASSOCIATIONS, CMD_LIEN,
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
  int canaux_controle, canaux_expression;
  int nassociations;
  struct association associations[MAX_ASSOCIATIONS];
  // Dernier contrôleur reçu, pour l'apprentissage depuis la page MIDI.
  int dernier_canal, dernier_cc, derniere_valeur;
  int xruns;
  int temps_reel;  // le fil audio a obtenu SCHED_FIFO
  int etape, netapes;  // combinaison courante (séquenceur), à partir de 0
  int midi_client, midi_port;
  int taux;
};

static struct etat *g_etat;  // partagée avec les fils de requêtes
static int g_tube[2] = {-1, -1};
static void *g_moteur;
static audio_t *g_audio;
static midi_t *g_midi;
static int g_periode;
static int g_maitre;  // processus qui fait tourner le moteur
// Propres au fil audio ; publiées dans g_etat.
static struct association g_associations[MAX_ASSOCIATIONS];
static int g_nassociations;
static int g_dernier[3] = {-1, -1, -1};

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
  int x = audio_xruns(g_audio);
  if (v != e->volume) e->volume = v, change = 1;
  if (r != e->reverb) e->reverb = r, change = 1;
  if (x != e->xruns) e->xruns = x, change = 1;
  int etape = aeolus_etape(g_moteur);
  if (etape != e->etape) e->etape = etape, change = 1;
  int cc = aeolus_canaux_controle(g_moteur), ce = aeolus_canaux_expression(g_moteur);
  if (cc != e->canaux_controle) e->canaux_controle = cc, change = 1;
  if (ce != e->canaux_expression) e->canaux_expression = ce, change = 1;
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

static void *boucle_audio(void *arg) {
  // Sous la priorité du fil de PipeWire (88) : il doit pouvoir nous
  // interrompre pour livrer le son. Il faut un droit « rtprio » (groupe
  // pipewire ou audio selon les systèmes) ; sinon on reste en temps partagé.
  struct sched_param sp = {.sched_priority = 70};
  g_etat->temps_reel = pthread_setschedparam(pthread_self(), SCHED_FIFO, &sp) == 0;

  float *g = malloc(g_periode * sizeof(float));
  float *d = malloc(g_periode * sizeof(float));
  float *entrelace = malloc(g_periode * 2 * sizeof(float));
  midi_msg_t msgs[64];
  struct commande cmds[32];
  int tours = 0;

  for (;;) {
    int n;
    while ((n = midi_lire(g_midi, msgs, 64)) > 0)
      for (int i = 0; i < n; ++i) {
        unsigned char m[3] = {msgs[i].statut, msgs[i].d1, msgs[i].d2};
        if ((m[0] & 0xF0) == 0xB0 && associer(m[0], m[1], m[2])) continue;
        aeolus_midi(g_moteur, m, 3);
      }
    ssize_t lu;
    while ((lu = read(g_tube[0], cmds, sizeof(cmds))) > 0)
      for (size_t i = 0; i < lu / sizeof(struct commande); ++i)
        appliquer(&cmds[i]);

    aeolus_rendre(g_moteur, g, d, g_periode);
    for (int i = 0; i < g_periode; ++i) {
      entrelace[2 * i] = g[i];
      entrelace[2 * i + 1] = d[i];
    }
    audio_ecrire(g_audio, entrelace, g_periode);

    if (++tours % 4 == 0) publier();  // ~40 ms à 512 trames
  }
  return arg;
}

// organum.demarrer{taux=48000, periode=512, peripherique="default",
//                  jeux={{division, jeu}, …}} → true | nil, erreur
static int l_demarrer(lua_State *L) {
  if (g_etat) return luaL_error(L, "organum déjà démarré");
  g_maitre = getpid();
  int taux = 48000, nb_periodes = 3;
  const char *peripherique = NULL;
  g_periode = 512;
  if (lua_istable(L, 1)) {
    lua_getfield(L, 1, "taux");
    if (lua_isinteger(L, -1)) taux = lua_tointeger(L, -1);
    lua_getfield(L, 1, "periode");
    if (lua_isinteger(L, -1)) g_periode = lua_tointeger(L, -1);
    lua_getfield(L, 1, "peripherique");
    if (lua_isstring(L, -1)) peripherique = lua_tostring(L, -1);
    lua_pop(L, 3);
  }

  g_etat = mmap(NULL, sizeof(struct etat), PROT_READ | PROT_WRITE,
                MAP_SHARED | MAP_ANONYMOUS, -1, 0);
  if (g_etat == MAP_FAILED) {
    g_etat = NULL;
    lua_pushnil(L);
    lua_pushstring(L, "mémoire partagée indisponible");
    return 2;
  }
  memset(g_etat, 0, sizeof(*g_etat));
  if (pipe(g_tube) < 0) {
    lua_pushnil(L);
    lua_pushstring(L, strerror(errno));
    return 2;
  }
  fcntl(g_tube[0], F_SETFL, O_NONBLOCK);

  g_moteur = aeolus_creer(taux);
  if (!(g_audio = audio_ouvrir(peripherique, taux, 2, g_periode, nb_periodes))) {
    lua_pushnil(L);
    lua_pushstring(L, "sortie audio indisponible");
    return 2;
  }
  if (!(g_midi = midi_ouvrir("Organum", "entree"))) {
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
  e->taux = taux;
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

  pthread_t fil;
  if (pthread_create(&fil, NULL, boucle_audio, NULL)) {
    lua_pushnil(L);
    lua_pushstring(L, "fil audio impossible");
    return 2;
  }
  pthread_detach(fil);
  lua_pushboolean(L, 1);
  return 1;
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

// organum.etat() → {seq, volume, reverb, xruns, taux, midi="c:p",
//                   divisions={{nom, gain, jeux={{nom, actif}, …}}, …}}
static int l_etat(lua_State *L) {
  struct etat *e = etat_ou_erreur(L);
  struct etat copie;
  // Copie cohérente : on recommence si le fil audio a publié entre-temps.
  unsigned seq;
  do {
    seq = atomic_load_explicit(&e->seq, memory_order_acquire);
    memcpy(&copie, e, sizeof(copie));
  } while (seq != atomic_load_explicit(&e->seq, memory_order_acquire));

  lua_createtable(L, 0, 7);
  lua_pushinteger(L, seq), lua_setfield(L, -2, "seq");
  lua_pushnumber(L, copie.volume), lua_setfield(L, -2, "volume");
  lua_pushnumber(L, copie.reverb), lua_setfield(L, -2, "reverb");
  lua_pushinteger(L, copie.xruns), lua_setfield(L, -2, "xruns");
  lua_pushboolean(L, copie.temps_reel), lua_setfield(L, -2, "temps_reel");
  lua_pushinteger(L, copie.etape), lua_setfield(L, -2, "etape");
  lua_pushinteger(L, copie.netapes), lua_setfield(L, -2, "netapes");
  lua_pushinteger(L, copie.taux), lua_setfield(L, -2, "taux");
  lua_pushfstring(L, "%d:%d", copie.midi_client, copie.midi_port);
  lua_setfield(L, -2, "midi");
  lua_pushinteger(L, copie.canaux_controle), lua_setfield(L, -2, "canaux_controle");
  lua_pushinteger(L, copie.canaux_expression), lua_setfield(L, -2, "canaux_expression");
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
  char *json = aeolus_sauvegarder(g_moteur);
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

static const luaL_Reg kFonctions[] = {
    {"demarrer", l_demarrer}, {"etat", l_etat},     {"attendre", l_attendre},
    {"jeu", l_jeu},           {"gain", l_gain},     {"volume", l_volume},
    {"reverb", l_reverb},     {"midi", l_midi},     {"panique", l_panique},
    {"canaux_division", l_canaux_division},
    {"canaux_controle", l_canaux_controle},
    {"canaux_expression", l_canaux_expression},
    {"associations", l_associations},
    {"lien", l_lien},
    {"sauvegarder", l_sauvegarder},
    {NULL, NULL},
};

int luaopen_organum(lua_State *L) {
  luaL_newlib(L, kFonctions);
  return 1;
}
