/* Assistant CoreMIDI et CoreAudio pour macOS, serveur des sockets d'organum.
 *
 * CoreMIDI et CoreAudio ne sont accessibles que depuis un binaire Mach-O :
 * cet assistant est le seul à leur parler. Il sert les deux protocoles
 * décrits dans PROTOCOLE-MIDI.md et PROTOCOLE-AUDIO.md :
 *
 *   - une socket MIDI (« OMID »), sur laquelle il publie les messages des
 *     sources CoreMIDI auxquelles organum s'abonne (codec trames_midi.h) ;
 *   - une socket audio (« OAUD ») et son fichier anneau `<socket>.pcm`, dans
 *     lequel il lit les échantillons float32 entrelacés déposés par organum
 *     et les joue via une AudioUnit de sortie par défaut (codec
 *     trames_audio.h, anneau anneau_audio.h).
 *
 * Les deux domaines sont indépendants : chacun a sa socket d'écoute, son
 * client, son état et son décodeur, et l'échec de l'un ne touche jamais
 * l'autre. Une seule boucle poll() surveille les quatre descripteurs ; le
 * processus ne sort que sur SIGINT ou SIGTERM (ou sur un échec de création
 * des deux domaines). Le rappel CoreMIDI et le rappel de rendu CoreAudio
 * tournent dans des fils Apple : ni l'un ni l'autre n'alloue, ne bloque ou
 * n'appelle de fonction libc évitable. Le fil principal possède les sockets,
 * les abonnements, l'AudioUnit et l'anneau.
 *
 * Licence : AGPL-3.0, comme le reste du dépôt (voir LICENSE.txt).
 */
#define _DARWIN_C_SOURCE 1

#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreMIDI/CoreMIDI.h>

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#include "anneau_audio.h"
#include "trames_audio.h"
#include "trames_midi.h"

#if defined(__clang__)
/* MIDIClientCreate et MIDIInputPortCreate (API historique, disponible depuis
   10.0) sont marquées obsolètes depuis macOS 11 au profit des variantes
   « WithProtocol », dont nous n'avons pas besoin. Le bruit est tué ici. */
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#endif

/* ------------------------------------------------------------------ */
/* Constantes communes et par domaine                                  */

#define TAMPON_ENTREE 512

#define MIDI_MAX_FRAME TRAMES_MIDI_MAX_FRAME_MAX
#define MIDI_TAILLE_MORCEAU 128
#define MIDI_VERIF_SOURCES 1 /* secondes entre deux énumérations de secours */

#define AUDIO_MAX_FRAME TRAMES_MAX_FRAME_MAX
#define AUDIO_DELAI_POLL 200 /* ms, période de la boucle principale */
#define AUDIO_DELAI_POIGNEE 150 /* ms, plus court que le délai d'organum */
#define CANAUX 2u
#define OCTETS_TRAME (CANAUX * sizeof(float))
/* Bornes de taux acceptées. Au-delà, l'unité refuserait de toute façon. */
#define TAUX_MIN 8000u
#define TAUX_MAX 192000u
/* Bloc de lecture du rappel : tampon de pile borné (4 Kio), plus petit que
   tout tampon CoreAudio usuel. Un rappel plus grand est lu en plusieurs
   blocs. */
#define TRAMES_PAR_BLOC 512u
/* Raisons d'AUDIO_STOP. */
#define RAISON_PERIPHERIQUE_PERDU 1u

/* Période de la boucle unique : assez courte pour la vérification annuelle
   des sources et du périphérique, assez longue pour ne pas tourner à vide. */
#define DELAI_POLL 200

/* ------------------------------------------------------------------ */
/* Journal commun : domaine toujours nommé                             */

static int g_verbose;
static volatile sig_atomic_t g_arret;

static void journal(const char *domaine, const char *format, ...)
{
  if (!g_verbose)
    return;
  va_list args;
  va_start(args, format);
  fprintf(stderr, "organum-helper : %s : ", domaine);
  vfprintf(stderr, format, args);
  fputc('\n', stderr);
  va_end(args);
}

static void erreur(const char *domaine, const char *format, ...)
{
  va_list args;
  va_start(args, format);
  fprintf(stderr, "organum-helper : %s : ", domaine);
  vfprintf(stderr, format, args);
  fputc('\n', stderr);
  va_end(args);
}

static void sur_signal(int sig)
{
  (void)sig;
  g_arret = 1;
}

/* ------------------------------------------------------------------ */
/* Utilitaires de socket partagés par les deux serveurs                */

/* Écrit tout, sans MSG_NOSIGNAL (SIGPIPE est ignoré). Renvoie 0 ou -1. */
static int ecrire_tout(int fd, const uint8_t *octets, size_t n)
{
  size_t fait = 0;
  while (fait < n) {
    const ssize_t w = send(fd, octets + fait, n - fait, 0);
    if (w > 0) {
      fait += (size_t)w;
      continue;
    }
    if (w < 0 && errno == EINTR)
      continue;
    return -1;
  }
  return 0;
}

static long long maintenant_ns(void)
{
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (long long)t.tv_sec * 1000000000LL + (long long)t.tv_nsec;
}

/* Lit exactement n octets, en abandonnant sur signal ou expiration du délai.
   Renvoie 0, -1 sur fin de flux, erreur ou délai dépassé. */
static int lire_exact(int fd, uint8_t *sortie, size_t n, int delai_ms)
{
  const long long echeance = maintenant_ns() + (long long)delai_ms * 1000000LL;
  size_t fait = 0;
  while (fait < n) {
    if (g_arret)
      return -1;
    const long long reste = echeance - maintenant_ns();
    if (reste <= 0)
      return -1;
    struct pollfd p = {fd, POLLIN, 0};
    const int r = poll(&p, 1, (int)(reste / 1000000LL) + 1);
    if (r < 0) {
      if (errno == EINTR)
        continue;
      return -1;
    }
    if (r == 0)
      continue;
    const ssize_t l = recv(fd, sortie + fait, n - fait, 0);
    if (l > 0)
      fait += (size_t)l;
    else if (l == 0)
      return -1;
    else if (errno != EINTR)
      return -1;
  }
  return 0;
}

/* Sonde une socket comme le prescrit le protocole : un assistant vivant garde
   la sienne, une socket périmée est remplacée. Renvoie le descripteur
   d'écoute, -3 si un autre assistant écoute déjà, -1 sur erreur. */
static int ouvrir_ecoute(const char *domaine, const char *chemin)
{
  struct sockaddr_un adresse;
  memset(&adresse, 0, sizeof adresse);
  adresse.sun_family = AF_UNIX;
  memcpy(adresse.sun_path, chemin, strlen(chemin) + 1);

  const int sonde = socket(AF_UNIX, SOCK_STREAM, 0);
  if (sonde < 0) {
    erreur(domaine, "socket : %s", strerror(errno));
    return -1;
  }
  if (connect(sonde, (struct sockaddr *)&adresse, sizeof adresse) == 0) {
    close(sonde);
    erreur(domaine, "un autre assistant écoute déjà sur %s", chemin);
    return -3;
  }
  const int e = errno;
  close(sonde);
  if (e != ENOENT && e != ECONNREFUSED) {
    erreur(domaine, "sonde de %s : %s", chemin, strerror(e));
    return -1;
  }

  umask(077);
  if (unlink(chemin) < 0 && errno != ENOENT) {
    erreur(domaine, "unlink %s : %s", chemin, strerror(errno));
    return -1;
  }

  const int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) {
    erreur(domaine, "socket : %s", strerror(errno));
    return -1;
  }
  if (bind(fd, (struct sockaddr *)&adresse, sizeof adresse) < 0) {
    erreur(domaine, "bind %s : %s", chemin, strerror(errno));
    close(fd);
    return -1;
  }
  if (chmod(chemin, 0600) < 0)
    erreur(domaine, "chmod %s : %s", chemin, strerror(errno));
  if (listen(fd, 1) < 0) {
    erreur(domaine, "listen %s : %s", chemin, strerror(errno));
    close(fd);
    unlink(chemin);
    return -1;
  }
  return fd;
}

/* ================================================================== */
/* Domaine MIDI                                                        */
/* ================================================================== */

enum etat_connexion_midi { MIDI_AUCUN = 0, MIDI_POIGNEE, MIDI_CONNECTE };

struct source {
  MIDIEndpointRef endpoint;
  SInt32 unique;
  char nom[TRAMES_MIDI_NOM_MAX + 1];
  uint8_t id; /* identifiant du protocole, 1..255 */
  int vu;      /* usage interne à midi_rafraichir_sources() */
  int connecte; /* port CoreMIDI connecté, fil principal seulement */
  _Atomic int actif;
};

static struct serveur_midi {
  MIDIClientRef client;
  MIDIPortRef port;
  int actif; /* client et port CoreMIDI utilisables */
  int ecoute;
  int client_fd; /* protégé par g_midi_ecriture */
  int proprietaire;
  char chemin[TRAMES_MIDI_SUN_PATH_MAX];

  struct source sources[TRAMES_MIDI_PERIPHERIQUES_MAX];

  enum etat_connexion_midi etat;
  uint8_t poignee[TRAMES_MIDI_POIGNEE_TAILLE];
  int poignee_recus;
  uint16_t max_frame;
  struct trame_decodeur decodeur;
  uint8_t entree[TAMPON_ENTREE];
  int debut, fin;

  time_t derniere_verif;
  _Atomic int sources_changees;
  _Atomic int client_ko;
  _Atomic int sysex_ouvert;
  _Atomic unsigned long trames_jetees;
} g_midi;

static pthread_mutex_t g_midi_ecriture = PTHREAD_MUTEX_INITIALIZER;

/* Abonnements par identifiant du protocole, et non par source : organum
   raisonne lui aussi par identifiant, et un identifiant libéré puis réutilisé
   doit retrouver le même état. */
static _Atomic int g_abonnement[256];

/* ------------------------------------------------------------------ */
/* Écriture des trames MIDI                                            */

static int midi_ecrire_tout_locked(const uint8_t *octets, size_t n)
{
  int fd = g_midi.client_fd;
  if (fd < 0)
    return -1;
  size_t fait = 0;
  while (fait < n) {
    ssize_t w = send(fd, octets + fait, n - fait, 0);
    if (w > 0) {
      fait += (size_t)w;
      continue;
    }
    if (w < 0 && errno == EINTR)
      continue;
    if (w < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
      /* Aucun blocage : la trame est perdue, la session aussi si elle a
         été coupée en deux. */
      g_midi.trames_jetees++;
      if (fait > 0)
        g_midi.client_ko = 1;
      return -1;
    }
    if (w == 0)
      errno = EPIPE;
    g_midi.client_ko = 1;
    return -1;
  }
  return 0;
}

static int midi_envoyer_brut(const uint8_t *octets, size_t n)
{
  pthread_mutex_lock(&g_midi_ecriture);
  int r = midi_ecrire_tout_locked(octets, n);
  pthread_mutex_unlock(&g_midi_ecriture);
  return r;
}

/* Trame de contrôle (ou MIDI court) : le corps tient dans MIDI_TAILLE_MORCEAU. */
static int midi_envoyer_trame(uint8_t type, uint8_t flags,
                              const uint8_t *corps, uint16_t longueur)
{
  uint8_t trame[TRAMES_MIDI_ENTETE_TAILLE + MIDI_TAILLE_MORCEAU];
  if (longueur > MIDI_TAILLE_MORCEAU)
    return -1;
  const int n =
      trame_encoder(trame, sizeof trame, type, flags, corps, longueur);
  if (n < 0)
    return -1;
  return midi_envoyer_brut(trame, (size_t)n);
}

/* ------------------------------------------------------------------ */
/* Rappel CoreMIDI : aucun blocage, aucune allocation                  */

static void midi_envoyer_midi_court(const uint8_t *corps, uint16_t longueur)
{
  if (!trame_midi_valide(corps, longueur))
    return;
  midi_envoyer_trame(TRAMES_MIDI_TYPE_MIDI, 0, corps, longueur);
}

/* Morceau de SysEx : découpe [debut, fin) en tranches de MIDI_TAILLE_MORCEAU.
   Le dernier morceau du message porte le drapeau 0, les autres SUITE. */
static void midi_envoyer_sysex(const uint8_t *donnees, size_t n, size_t debut)
{
  size_t fin = debut;
  int trouve = 0;
  while (fin < n) {
    if (donnees[fin] == 0xF7) {
      trouve = 1;
      break;
    }
    ++fin;
  }
  const size_t limite = trouve ? fin + 1 : n;
  size_t pos = debut;
  while (pos < limite) {
    size_t reste = limite - pos;
    size_t prendre = reste > MIDI_TAILLE_MORCEAU ? MIDI_TAILLE_MORCEAU : reste;
    const int suite = (pos + prendre < limite) || !trouve;
    midi_envoyer_trame(TRAMES_MIDI_TYPE_SYSEX,
                       suite ? TRAMES_MIDI_FLAG_SUITE : 0, donnees + pos,
                       (uint16_t)prendre);
    pos += prendre;
  }
  g_midi.sysex_ouvert = !trouve;
}

static void midi_traiter_paquet(const uint8_t *d, size_t n)
{
  size_t i = 0;

  /* Un SysEx commencé dans un paquet précédent reprend sans 0xF0. */
  if (g_midi.sysex_ouvert) {
    size_t j = 0;
    while (j < n && d[j] != 0xF7)
      ++j;
    midi_envoyer_sysex(d, j < n ? j + 1 : n, 0);
    i = j < n ? j + 1 : n;
  }

  while (i < n) {
    const uint8_t b = d[i];
    if (b >= 0xF8) { /* temps réel : un octet, non transmis en v1 */
      ++i;
      continue;
    }
    if (b == 0xF0) {
      size_t j = i + 1;
      while (j < n && d[j] != 0xF7)
        ++j;
      midi_envoyer_sysex(d, j < n ? j + 1 : n, i);
      i = j < n ? j + 1 : n;
      continue;
    }
    if (b == 0xF7) { /* fin de SysEx orpheline */
      g_midi.sysex_ouvert = 0;
      ++i;
      continue;
    }
    if (b >= 0xF1) { /* système commun : longueur connue, non transmis */
      size_t longueur = 1;
      if (b == 0xF1 || b == 0xF3)
        longueur = 2;
      else if (b == 0xF2)
        longueur = 3;
      i += longueur;
      continue;
    }
    if (b < 0x80) { /* octet de données orphelin */
      ++i;
      continue;
    }
    const size_t longueur = ((b & 0xE0) == 0xC0) ? 2 : 3;
    if (i + longueur <= n)
      midi_envoyer_midi_court(d + i, (uint16_t)longueur);
    i += longueur;
  }
}

static void midi_lire(const MIDIPacketList *liste, void *refcon,
                      void *source_refcon)
{
  (void)refcon;
  const struct source *source = source_refcon;
  if (source == NULL || source->id == 0 ||
      !atomic_load(&g_abonnement[source->id]))
    return;

  const MIDIPacket *p = &liste->packet[0];
  for (UInt32 k = 0; k < liste->numPackets; ++k) {
    midi_traiter_paquet(p->data, p->length);
    p = MIDIPacketNext(p);
  }
}

static void midi_notifier(const MIDINotification *message, void *refcon)
{
  (void)message;
  (void)refcon;
  g_midi.sources_changees = 1;
}

/* ------------------------------------------------------------------ */
/* Sources MIDI                                                        */

static void midi_copier_nom(MIDIEndpointRef endpoint, char *sortie,
                            size_t capacite)
{
  CFStringRef nom = NULL;
  if (MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &nom) !=
          noErr ||
      nom == NULL) {
    nom = NULL;
    if (MIDIObjectGetStringProperty(endpoint, kMIDIPropertyName, &nom) !=
        noErr)
      nom = NULL;
  }
  sortie[0] = '\0';
  if (nom != NULL && capacite > 1) {
    CFIndex utilise = 0;
    CFStringGetBytes(nom, CFRangeMake(0, CFStringGetLength(nom)),
                     kCFStringEncodingUTF8, (UInt8)'?', (Boolean)0,
                     (UInt8 *)sortie, (CFIndex)(capacite - 1), &utilise);
    sortie[utilise] = '\0';
    CFRelease(nom);
  }
  if (sortie[0] == '\0')
    snprintf(sortie, capacite, "source sans nom");
}

static int midi_id_libre(void)
{
  for (int id = 1; id <= 255; ++id) {
    int pris = 0;
    for (int i = 0; i < TRAMES_MIDI_PERIPHERIQUES_MAX; ++i)
      if (atomic_load(&g_midi.sources[i].actif) &&
          g_midi.sources[i].id == id) {
        pris = 1;
        break;
      }
    if (!pris)
      return id;
  }
  return 0;
}

static int midi_trouver_source_par_id(uint8_t id)
{
  for (int i = 0; i < TRAMES_MIDI_PERIPHERIQUES_MAX; ++i)
    if (atomic_load(&g_midi.sources[i].actif) && g_midi.sources[i].id == id)
      return i;
  return -1;
}

/* Énumère les sources, connecte les nouvelles, déconnecte les disparues.
   Renvoie 1 si la liste publiée a changé. Fil principal uniquement. */
static int midi_rafraichir_sources(void)
{
  int change = 0;
  for (int i = 0; i < TRAMES_MIDI_PERIPHERIQUES_MAX; ++i)
    g_midi.sources[i].vu = 0;

  const ItemCount n = MIDIGetNumberOfSources();
  for (ItemCount k = 0; k < n; ++k) {
    const MIDIEndpointRef endpoint = MIDIGetSource(k);
    if (endpoint == 0)
      continue;

    SInt32 unique = 0;
    if (MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID,
                                     &unique) != noErr)
      unique = 0;

    int i = -1;
    for (int j = 0; j < TRAMES_MIDI_PERIPHERIQUES_MAX; ++j) {
      if (!atomic_load(&g_midi.sources[j].actif))
        continue;
      if (g_midi.sources[j].endpoint == endpoint ||
          (unique != 0 && g_midi.sources[j].unique == unique)) {
        i = j;
        break;
      }
    }

    if (i < 0) {
      for (int j = 0; j < TRAMES_MIDI_PERIPHERIQUES_MAX; ++j)
        if (!atomic_load(&g_midi.sources[j].actif)) {
          i = j;
          break;
        }
      if (i < 0) {
        journal("midi", "source ignorée : maximum de %d atteint",
                TRAMES_MIDI_PERIPHERIQUES_MAX);
        continue;
      }
      g_midi.sources[i].endpoint = endpoint;
      g_midi.sources[i].unique = unique;
      g_midi.sources[i].id = (uint8_t)midi_id_libre();
      g_midi.sources[i].vu = 1;
      midi_copier_nom(endpoint, g_midi.sources[i].nom,
                      sizeof g_midi.sources[i].nom);
      atomic_store(&g_midi.sources[i].actif, 1);
      const OSStatus st =
          MIDIPortConnectSource(g_midi.port, endpoint, &g_midi.sources[i]);
      g_midi.sources[i].connecte = st == noErr;
      if (st != noErr)
        erreur("midi", "connexion de la source « %s » impossible (%d)",
               g_midi.sources[i].nom, (int)st);
      else
        journal("midi", "source %u « %s » (unique %ld) connectée",
                g_midi.sources[i].id, g_midi.sources[i].nom, (long)unique);
      change = 1;
      continue;
    }

    /* Même identité, autre point d'entrée : rebrancher. */
    if (g_midi.sources[i].endpoint != endpoint) {
      MIDIPortDisconnectSource(g_midi.port, g_midi.sources[i].endpoint);
      g_midi.sources[i].endpoint = endpoint;
      if (unique != 0)
        g_midi.sources[i].unique = unique;
      midi_copier_nom(endpoint, g_midi.sources[i].nom,
                      sizeof g_midi.sources[i].nom);
      g_midi.sources[i].connecte =
          MIDIPortConnectSource(g_midi.port, endpoint, &g_midi.sources[i]) ==
          noErr;
      if (!g_midi.sources[i].connecte)
        erreur("midi", "reconnexion de la source « %s » impossible",
               g_midi.sources[i].nom);
      change = 1;
    }

    /* Une source hors ligne à la découverte est réessayée à chaque tour. */
    if (!g_midi.sources[i].connecte &&
        MIDIPortConnectSource(g_midi.port, endpoint, &g_midi.sources[i]) ==
            noErr) {
      g_midi.sources[i].connecte = 1;
      journal("midi", "source %u « %s » connectée", g_midi.sources[i].id,
              g_midi.sources[i].nom);
    }
    g_midi.sources[i].vu = 1;
  }

  for (int i = 0; i < TRAMES_MIDI_PERIPHERIQUES_MAX; ++i) {
    if (!atomic_load(&g_midi.sources[i].actif) || g_midi.sources[i].vu)
      continue;
    MIDIPortDisconnectSource(g_midi.port, g_midi.sources[i].endpoint);
    g_midi.sources[i].connecte = 0;
    atomic_store(&g_midi.sources[i].actif, 0);
    journal("midi", "source %u « %s » retirée", g_midi.sources[i].id,
            g_midi.sources[i].nom);
    change = 1;
  }
  return change;
}

/* DEVICE_LIST complète, publiée après tout changement et à la connexion. */
static void midi_envoyer_liste(void)
{
  uint8_t corps[1 + TRAMES_MIDI_PERIPHERIQUES_MAX *
                        (3 + TRAMES_MIDI_NOM_MAX)];
  size_t i = 1;
  unsigned long n = 0;
  for (int k = 0; k < TRAMES_MIDI_PERIPHERIQUES_MAX; ++k) {
    if (!atomic_load(&g_midi.sources[k].actif) ||
        g_midi.sources[k].endpoint == 0)
      continue;
    if (n >= TRAMES_MIDI_PERIPHERIQUES_MAX)
      break;
    size_t longueur = strlen(g_midi.sources[k].nom);
    if (longueur > TRAMES_MIDI_NOM_MAX)
      longueur = TRAMES_MIDI_NOM_MAX;
    corps[i++] = g_midi.sources[k].id;
    corps[i++] = TRAMES_MIDI_CAPACITE_SOURCE;
    corps[i++] = (uint8_t)longueur;
    memcpy(corps + i, g_midi.sources[k].nom, longueur);
    i += longueur;
    ++n;
  }
  corps[0] = (uint8_t)n;

  uint8_t trame[TRAMES_MIDI_ENTETE_TAILLE + sizeof corps];
  const int t = trame_encoder(trame, sizeof trame,
                              TRAMES_MIDI_TYPE_DEVICE_LIST, 0, corps,
                              (uint16_t)i);
  if (t < 0) {
    erreur("midi", "DEVICE_LIST trop grande");
    return;
  }
  if (midi_envoyer_brut(trame, (size_t)t) < 0)
    journal("midi", "DEVICE_LIST perdue (écriture impossible)");
  else
    journal("midi", "DEVICE_LIST publiée (%lu source(s))", n);
}

/* ------------------------------------------------------------------ */
/* Connexion organum (MIDI)                                            */

static void midi_fermer_client_adieu(int adieu)
{
  if (g_midi.etat == MIDI_AUCUN)
    return;
  if (adieu && g_midi.etat == MIDI_CONNECTE)
    midi_envoyer_trame(TRAMES_MIDI_TYPE_BYE, 0, NULL, 0);

  pthread_mutex_lock(&g_midi_ecriture);
  if (g_midi.client_fd >= 0)
    close(g_midi.client_fd);
  g_midi.client_fd = -1;
  pthread_mutex_unlock(&g_midi_ecriture);

  for (int i = 0; i < 256; ++i)
    atomic_store(&g_abonnement[i], 0);

  g_midi.etat = MIDI_AUCUN;
  g_midi.poignee_recus = 0;
  g_midi.debut = 0;
  g_midi.fin = 0;
  g_midi.sysex_ouvert = 0;
  g_midi.client_ko = 0;
  journal("midi", "client déconnecté");
}

static void midi_fermer_client(void)
{
  midi_fermer_client_adieu(1);
}

static void midi_accepter_client(void)
{
  const int fd = accept(g_midi.ecoute, NULL, NULL);
  if (fd < 0) {
    if (errno != EINTR)
      erreur("midi", "accept : %s", strerror(errno));
    return;
  }

  /* Aucun LOCAL_PEERPID : le helper est lancé par organum et doit mourir avec
     le groupe de processus de son parent, comme le fait redbean à l'arrêt de
     l'orgue. La protection du client précédente est retirée volontairement. */

  if (g_midi.etat != MIDI_AUCUN) {
    uint8_t reponse[TRAMES_MIDI_POIGNEE_TAILLE];
    poignee_encoder(reponse, TRAMES_MIDI_STATUT_CLIENT, MIDI_MAX_FRAME);
    ecrire_tout(fd, reponse, sizeof reponse);
    close(fd);
    journal("midi", "deuxième client refusé (déjà un abonné)");
    return;
  }

  const int drapeaux = fcntl(fd, F_GETFL, 0);
  if (drapeaux >= 0)
    fcntl(fd, F_SETFL, drapeaux | O_NONBLOCK);

  pthread_mutex_lock(&g_midi_ecriture);
  g_midi.client_fd = fd;
  pthread_mutex_unlock(&g_midi_ecriture);

  g_midi.etat = MIDI_POIGNEE;
  g_midi.poignee_recus = 0;
  g_midi.debut = 0;
  g_midi.fin = 0;
  g_midi.sysex_ouvert = 0;
  g_midi.client_ko = 0;
  journal("midi", "client connecté");
}

/* Traite ce qui est déjà dans g_midi.entree. Renvoie -1 si la session
   s'arrête. */
static int midi_traiter_entree(void)
{
  for (;;) {
    if (g_midi.etat == MIDI_POIGNEE) {
      const size_t dispo = (size_t)(g_midi.fin - g_midi.debut);
      size_t prendre =
          (size_t)(TRAMES_MIDI_POIGNEE_TAILLE - g_midi.poignee_recus);
      if (prendre > dispo)
        prendre = dispo;
      memcpy(g_midi.poignee + g_midi.poignee_recus, g_midi.entree + g_midi.debut,
             prendre);
      g_midi.debut += (int)prendre;
      g_midi.poignee_recus += (int)prendre;
      if (g_midi.poignee_recus < TRAMES_MIDI_POIGNEE_TAILLE) {
        g_midi.debut = g_midi.fin = 0;
        return 0;
      }

      struct poignee_vue vue;
      const int code = poignee_decoder(g_midi.poignee, &vue);
      uint8_t statut = TRAMES_MIDI_STATUT_INTERNE;
      if (code == 1)
        statut = TRAMES_MIDI_STATUT_OK;
      else if (code == -2)
        statut = TRAMES_MIDI_STATUT_VERSION;

      if (statut != TRAMES_MIDI_STATUT_OK) {
        uint8_t reponse[TRAMES_MIDI_POIGNEE_TAILLE];
        poignee_encoder(reponse, statut, MIDI_MAX_FRAME);
        midi_envoyer_brut(reponse, sizeof reponse);
        journal("midi", "poignée refusée (code %d)", code);
        midi_fermer_client();
        return -1;
      }

      g_midi.max_frame = vue.max_frame;
      if (g_midi.max_frame > MIDI_MAX_FRAME)
        g_midi.max_frame = MIDI_MAX_FRAME;
      trame_decodeur_init(&g_midi.decodeur, g_midi.max_frame);
      if (g_midi.debut == g_midi.fin)
        g_midi.debut = g_midi.fin = 0;
      g_midi.etat = MIDI_CONNECTE;

      uint8_t reponse[TRAMES_MIDI_POIGNEE_TAILLE];
      poignee_encoder(reponse, TRAMES_MIDI_STATUT_OK, MIDI_MAX_FRAME);
      if (midi_envoyer_brut(reponse, sizeof reponse) < 0) {
        midi_fermer_client();
        return -1;
      }
      journal("midi", "poignée acceptée (max_frame %u)", g_midi.max_frame);
      midi_envoyer_liste();
      continue;
    }

    struct trame_vue vue;
    size_t consommes = 0;
    const int code =
        trame_decoder(&g_midi.decodeur, g_midi.entree + g_midi.debut,
                      (size_t)(g_midi.fin - g_midi.debut), &vue, &consommes);
    if (code < 0) {
      erreur("midi", "longueur de trame supérieure à max_frame : fermeture");
      midi_fermer_client();
      return -1;
    }
    if (code == 0) {
      g_midi.debut = g_midi.fin = 0;
      return 0;
    }
    g_midi.debut += (int)consommes;

    switch (vue.type) {
    case TRAMES_MIDI_TYPE_PING:
      midi_envoyer_trame(TRAMES_MIDI_TYPE_PONG, 0, NULL, 0);
      break;
    case TRAMES_MIDI_TYPE_SUBSCRIBE:
      if (vue.longueur >= 2) {
        const int actif = vue.corps[1] != 0;
        atomic_store(&g_abonnement[vue.corps[0]], actif);
        const int i = midi_trouver_source_par_id(vue.corps[0]);
        if (i >= 0)
          journal("midi", "source %u « %s » %s", g_midi.sources[i].id,
                  g_midi.sources[i].nom, actif ? "abonnée" : "désabonnée");
        else
          journal("midi", "source %u (absente) %s", vue.corps[0],
                  actif ? "abonnée" : "désabonnée");
      }
      break;
    case TRAMES_MIDI_TYPE_BYE:
      journal("midi", "BYE reçu d'organum");
      midi_fermer_client_adieu(0);
      /* Fin de session normale : la socket d'écoute et les sources CoreMIDI
         restent en place, le prochain organum sera accepté. */
      return 0;
    default:
      break; /* type inconnu : trame lue puis ignorée */
    }
    if (g_midi.debut == g_midi.fin)
      g_midi.debut = g_midi.fin = 0;
  }
}

static int midi_lire_client(void)
{
  if (g_midi.etat == MIDI_AUCUN)
    return 0;
  if (g_midi.debut == g_midi.fin)
    g_midi.debut = g_midi.fin = 0;
  if (g_midi.fin >= (int)sizeof g_midi.entree) {
    erreur("midi", "tampon d'entrée saturé : fermeture");
    midi_fermer_client();
    return -1;
  }

  const ssize_t r = recv(g_midi.client_fd, g_midi.entree + g_midi.fin,
                         sizeof g_midi.entree - (size_t)g_midi.fin, 0);
  if (r == 0) {
    journal("midi", "fin de flux");
    midi_fermer_client();
    /* Le client est parti : on revient à l'écoute sans toucher aux sources
       CoreMIDI ni à la socket. */
    return 0;
  }
  if (r < 0) {
    if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)
      return 0;
    erreur("midi", "lecture de la socket : %s", strerror(errno));
    midi_fermer_client();
    return -1;
  }
  g_midi.fin += (int)r;
  return midi_traiter_entree();
}

/* ------------------------------------------------------------------ */
/* Diagnostic --liste (MIDI)                                           */

static int midi_lister_sources(void)
{
  MIDIClientRef client = 0;
  const OSStatus st =
      MIDIClientCreate(CFSTR("organum-helper"), NULL, NULL, &client);
  if (st != noErr) {
    erreur("midi", "création du client CoreMIDI impossible (%d)", (int)st);
    return 1;
  }

  const ItemCount n = MIDIGetNumberOfSources();
  if (n == 0) {
    printf("organum-helper : midi : aucune source MIDI détectée.\n");
    printf("organum-helper : midi : ouvrez « Configuration audio et MIDI », "
           "menu Fenêtre → Afficher le studio MIDI,\n"
           "organum-helper : midi : double-cliquez sur « IAC Driver » et "
           "cochez « Périphérique en ligne »,\n"
           "organum-helper : midi : ou branchez un clavier MIDI USB.\n");
  } else {
    printf("organum-helper : midi : %lu source(s) MIDI :\n", (unsigned long)n);
    for (ItemCount k = 0; k < n; ++k) {
      const MIDIEndpointRef endpoint = MIDIGetSource(k);
      SInt32 unique = 0;
      MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &unique);
      char nom[TRAMES_MIDI_NOM_MAX + 1];
      midi_copier_nom(endpoint, nom, sizeof nom);
      printf("organum-helper : midi :   unique %-10ld %s\n", (long)unique,
             nom);
    }
  }

  MIDIClientDispose(client);
  return 0;
}

/* ------------------------------------------------------------------ */
/* Arrêt du domaine MIDI                                               */

static void midi_arreter(void)
{
  midi_fermer_client();
  for (int i = 0; i < TRAMES_MIDI_PERIPHERIQUES_MAX; ++i) {
    if (!atomic_load(&g_midi.sources[i].actif))
      continue;
    if (g_midi.port != 0)
      MIDIPortDisconnectSource(g_midi.port, g_midi.sources[i].endpoint);
    g_midi.sources[i].connecte = 0;
    atomic_store(&g_midi.sources[i].actif, 0);
  }
  if (g_midi.port != 0)
    MIDIPortDispose(g_midi.port);
  if (g_midi.client != 0)
    MIDIClientDispose(g_midi.client);
  g_midi.port = 0;
  g_midi.client = 0;
  g_midi.actif = 0;
  if (g_midi.ecoute >= 0) {
    close(g_midi.ecoute);
    g_midi.ecoute = -1;
  }
  if (g_midi.proprietaire) {
    if (unlink(g_midi.chemin) < 0 && errno != ENOENT)
      erreur("midi", "unlink %s : %s", g_midi.chemin, strerror(errno));
    g_midi.proprietaire = 0;
  }
}

/* Démarre le domaine MIDI. Un échec laisse simplement le MIDI indisponible :
   l'audio continue. Renvoie 0, -3 si un autre assistant écoute déjà. */
static int midi_demarrer(void)
{
  const int ecoute = ouvrir_ecoute("midi", g_midi.chemin);
  if (ecoute < 0)
    return ecoute == -3 ? -3 : -1;
  g_midi.ecoute = ecoute;
  g_midi.proprietaire = 1;

  if (MIDIClientCreate(CFSTR("organum-helper"), midi_notifier, NULL,
                       &g_midi.client) != noErr) {
    erreur("midi", "création du client CoreMIDI impossible : MIDI "
                   "indisponible, l'audio continue");
    midi_arreter();
    return -1;
  }
  if (MIDIInputPortCreate(g_midi.client, CFSTR("organum-helper"), midi_lire,
                          NULL, &g_midi.port) != noErr) {
    erreur("midi", "création du port d'entrée CoreMIDI impossible : MIDI "
                   "indisponible, l'audio continue");
    midi_arreter();
    return -1;
  }

  g_midi.actif = 1;
  g_midi.derniere_verif = time(NULL);
  journal("midi", "écoute sur %s", g_midi.chemin);
  if (midi_rafraichir_sources() == 0)
    journal("midi", "aucune source CoreMIDI pour l'instant");
  else
    journal("midi", "sources CoreMIDI présentes");
  return 0;
}

/* Un tour de service du domaine MIDI : pompage du run loop, rafraîchissement
   des sources et envoi de la liste. Aucune interaction avec l'audio. */
static void midi_servir(void)
{
  if (!g_midi.actif)
    return;

  /* CoreMIDI ne livre ses notifications et n'actualise son cache de sources
     que sur le run loop du fil qui a créé le client. Sans ce pompage, une
     source branchée à chaud reste invisible malgré l'énumération de secours,
     et le rappel de lecture n'est jamais appelé. Le délai nul rend la main
     aussitôt : le fil continue de servir les sockets avec son poll(). */
  CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.0, true);
  if (g_midi.client_ko && g_midi.etat != MIDI_AUCUN)
    midi_fermer_client();

  const time_t maintenant = time(NULL);
  if (g_midi.sources_changees || maintenant != g_midi.derniere_verif) {
    g_midi.sources_changees = 0;
    g_midi.derniere_verif = maintenant;
    if (midi_rafraichir_sources() && g_midi.etat == MIDI_CONNECTE)
      midi_envoyer_liste();
  }
}

/* ================================================================== */
/* Domaine audio                                                       */
/* ================================================================== */

enum etat_connexion_audio { AUDIO_AUCUN = 0, AUDIO_CONNECTE };

struct sortie {
  AudioObjectID objet;
  char nom[TRAMES_AUDIO_NOM_MAX + 1];
  uint32_t taux;   /* taux nominal du périphérique, 0 si inconnu */
  uint32_t canaux; /* canaux de sortie du périphérique */
  uint32_t latence_us;
};

static struct serveur_audio {
  int ecoute;
  int client_fd;
  int proprietaire; /* la socket est à nous : on la retire à l'arrêt */
  int pcm_proprietaire;
  char chemin[TRAMES_SUN_PATH_MAX];
  char chemin_pcm[TRAMES_SUN_PATH_MAX + 8];

  struct anneau_entete *anneau;
  size_t taille_anneau;
  uint32_t capacite;

  AudioUnit unite;
  int initialisee;
  int demarre;
  int non_entrelace;
  uint32_t taux;
  uint32_t periode;

  enum etat_connexion_audio etat;
  struct trame_decodeur decodeur;
  uint8_t entree[TAMPON_ENTREE];
  int debut, fin;
  uint16_t max_frame;

  _Atomic int peripherique_change;
  time_t derniere_verif;
} g_audio;

/* Horloge : binaire Mach-O compilé par le clang d'Apple, donc CLOCK_MONOTONIC
   est celui de la libc native. Il n'a pas le défaut de diviseur TSC de
   cosmocc sous XNU, et aucune durée « humaine » n'est mesurée ici.
   maintenant_ns() est défini avec les utilitaires communs. */

/* ------------------------------------------------------------------ */
/* Sortie audio : interrogation du périphérique par défaut             */

static int audio_canaux_sortie(AudioObjectID device, uint32_t *canaux)
{
  AudioObjectPropertyAddress a = {kAudioDevicePropertyStreamConfiguration,
                                  kAudioDevicePropertyScopeOutput,
                                  kAudioObjectPropertyElementMain};
  UInt32 taille = 0;
  if (AudioObjectGetPropertyDataSize(device, &a, 0, NULL, &taille) != noErr ||
      taille == 0)
    return 0;
  AudioBufferList *liste = malloc(taille);
  if (liste == NULL)
    return 0;
  if (AudioObjectGetPropertyData(device, &a, 0, NULL, &taille, liste) !=
      noErr) {
    free(liste);
    return 0;
  }
  uint32_t total = 0;
  for (UInt32 i = 0; i < liste->mNumberBuffers; ++i)
    total += liste->mBuffers[i].mNumberChannels;
  free(liste);
  *canaux = total;
  return 1;
}

static void audio_nom_sortie(AudioObjectID device, char *sortie,
                             size_t capacite)
{
  sortie[0] = '\0';
  CFStringRef nom = NULL;
  AudioObjectPropertyAddress a = {kAudioObjectPropertyName,
                                  kAudioObjectPropertyScopeGlobal,
                                  kAudioObjectPropertyElementMain};
  UInt32 taille = sizeof nom;
  if (AudioObjectGetPropertyData(device, &a, 0, NULL, &taille, &nom) ==
          noErr &&
      nom != NULL) {
    if (!CFStringGetCString(nom, sortie, (CFIndex)capacite,
                            kCFStringEncodingUTF8))
      sortie[0] = '\0';
    CFRelease(nom);
  }
  if (sortie[0] == '\0')
    snprintf(sortie, capacite, "sortie système");
}

static uint32_t audio_latence_us(AudioObjectID device, uint32_t taux)
{
  if (taux == 0)
    return 0;
  UInt32 latence = 0, securite = 0, tampon = 0;
  AudioObjectPropertyAddress a = {kAudioDevicePropertyLatency,
                                  kAudioDevicePropertyScopeOutput,
                                  kAudioObjectPropertyElementMain};
  UInt32 taille = sizeof latence;
  if (AudioObjectGetPropertyData(device, &a, 0, NULL, &taille, &latence) !=
      noErr)
    latence = 0;
  a.mSelector = kAudioDevicePropertySafetyOffset;
  taille = sizeof securite;
  if (AudioObjectGetPropertyData(device, &a, 0, NULL, &taille, &securite) !=
      noErr)
    securite = 0;
  a.mSelector = kAudioDevicePropertyBufferFrameSize;
  taille = sizeof tampon;
  if (AudioObjectGetPropertyData(device, &a, 0, NULL, &taille, &tampon) !=
      noErr)
    tampon = 0;
  const uint64_t total = (uint64_t)latence + securite + tampon;
  return (uint32_t)(total * 1000000ULL / (uint64_t)taux);
}

/* Remplit s et renvoie 1 si un périphérique de sortie par défaut existe et
   possède au moins un canal de sortie. 0 sinon. */
static int audio_interroger_sortie(struct sortie *s)
{
  if (s != NULL)
    memset(s, 0, sizeof *s);

  AudioObjectID device = kAudioObjectUnknown;
  UInt32 taille = sizeof device;
  AudioObjectPropertyAddress a = {kAudioHardwarePropertyDefaultOutputDevice,
                                  kAudioObjectPropertyScopeGlobal,
                                  kAudioObjectPropertyElementMain};
  if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL,
                                 &taille, &device) != noErr)
    return 0;
  if (device == 0 || device == kAudioObjectUnknown)
    return 0;

  uint32_t canaux = 0;
  if (!audio_canaux_sortie(device, &canaux) || canaux == 0)
    return 0;

  Float64 taux = 0;
  a.mSelector = kAudioDevicePropertyNominalSampleRate;
  a.mScope = kAudioObjectPropertyScopeGlobal;
  taille = sizeof taux;
  if (AudioObjectGetPropertyData(device, &a, 0, NULL, &taille, &taux) !=
          noErr ||
      taux <= 0.0)
    taux = 0.0;

  if (s != NULL) {
    s->objet = device;
    s->canaux = canaux;
    s->taux = (uint32_t)taux;
    audio_nom_sortie(device, s->nom, sizeof s->nom);
    s->latence_us = audio_latence_us(device, s->taux);
  }
  return 1;
}

/* ------------------------------------------------------------------ */
/* Rappel de rendu : aucun verrou, aucune allocation, aucun appel bloquant */

static OSStatus audio_rendre(void *refcon, AudioUnitRenderActionFlags *drapeaux,
                             const AudioTimeStamp *horodatage, UInt32 bus,
                             UInt32 trames, AudioBufferList *donnees)
{
  (void)refcon;
  (void)drapeaux;
  (void)horodatage;
  (void)bus;

  if (donnees == NULL || donnees->mNumberBuffers == 0)
    return noErr;

  float melange[TRAMES_PAR_BLOC * CANAUX];
  UInt32 position = 0;
  UInt32 restant = trames;
  while (restant > 0) {
    const UInt32 bloc = restant > TRAMES_PAR_BLOC ? TRAMES_PAR_BLOC : restant;
    size_t lues = 0;
    /* Un anneau arrêté (arret posé) ne rend rien : le bloc est du silence. */
    if (g_audio.anneau != NULL)
      lues = anneau_lire(g_audio.anneau, melange, (size_t)bloc);
    if (lues < (size_t)bloc)
      memset(melange + lues * CANAUX, 0,
             ((size_t)bloc - lues) * OCTETS_TRAME);

    if (g_audio.non_entrelace) {
      for (UInt32 c = 0; c < donnees->mNumberBuffers && c < CANAUX; ++c) {
        AudioBuffer *b = &donnees->mBuffers[c];
        if (b->mData == NULL)
          continue;
        float *dst = (float *)b->mData;
        const UInt32 par_trame =
            b->mNumberChannels != 0 ? b->mNumberChannels : 1u;
        UInt32 dispo = trames;
        if (b->mDataByteSize != 0)
          dispo = (UInt32)(b->mDataByteSize / ((size_t)par_trame *
                                               sizeof(float)));
        if (position >= dispo)
          continue;
        UInt32 n = bloc;
        if (position + n > dispo)
          n = dispo - position;
        for (UInt32 i = 0; i < n; ++i)
          dst[position + i] = melange[i * CANAUX + c];
      }
    } else {
      AudioBuffer *b = &donnees->mBuffers[0];
      if (b->mData != NULL) {
        float *dst = (float *)b->mData;
        UInt32 dispo = trames;
        if (b->mDataByteSize != 0)
          dispo = (UInt32)(b->mDataByteSize / OCTETS_TRAME);
        if (position < dispo) {
          UInt32 n = bloc;
          if (position + n > dispo)
            n = dispo - position;
          memcpy(dst + (size_t)position * CANAUX, melange,
                 (size_t)n * OCTETS_TRAME);
        }
      }
    }

    position += bloc;
    restant -= bloc;
  }
  return noErr;
}

/* ------------------------------------------------------------------ */
/* AudioUnit                                                           */

static void audio_arreter_unite(void)
{
  if (g_audio.unite == 0)
    return;
  if (g_audio.demarre) {
    AudioOutputUnitStop(g_audio.unite);
    g_audio.demarre = 0;
  }
  if (g_audio.initialisee) {
    AudioUnitUninitialize(g_audio.unite);
    g_audio.initialisee = 0;
  }
}

static void audio_detruire_unite(void)
{
  audio_arreter_unite();
  if (g_audio.unite != 0)
    AudioComponentInstanceDispose(g_audio.unite);
  g_audio.unite = 0;
}

/* Crée si besoin, formate, initialise et démarre l'unité de sortie.
   Renvoie un statut AUDIO_ACK. Un échec ne touche jamais le MIDI. */
static uint8_t audio_preparer_unite(uint32_t taux)
{
  if (g_audio.unite == 0) {
    AudioComponentDescription desc;
    memset(&desc, 0, sizeof desc);
    desc.componentType = kAudioUnitType_Output;
    desc.componentSubType = kAudioUnitSubType_DefaultOutput;
    desc.componentManufacturer = kAudioUnitManufacturer_Apple;
    AudioComponent composant = AudioComponentFindNext(NULL, &desc);
    if (composant == NULL) {
      erreur("audio", "aucune unité de sortie CoreAudio (DefaultOutput)");
      return TRAMES_AUDIO_STATUT_AUCUNE_SORTIE;
    }
    const OSStatus st = AudioComponentInstanceNew(composant, &g_audio.unite);
    if (st != noErr) {
      erreur("audio", "création de l'unité de sortie impossible (%d)",
             (int)st);
      g_audio.unite = 0;
      return TRAMES_AUDIO_STATUT_AUCUNE_SORTIE;
    }
  }

  AudioStreamBasicDescription fmt;
  memset(&fmt, 0, sizeof fmt);
  fmt.mSampleRate = (Float64)taux;
  fmt.mFormatID = kAudioFormatLinearPCM;
  fmt.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
  fmt.mFramesPerPacket = 1;
  fmt.mChannelsPerFrame = CANAUX;
  fmt.mBitsPerChannel = 32;
  fmt.mBytesPerFrame = CANAUX * sizeof(float);
  fmt.mBytesPerPacket = fmt.mBytesPerFrame;

  g_audio.non_entrelace = 0;
  OSStatus st = AudioUnitSetProperty(
      g_audio.unite, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
      &fmt, sizeof fmt);
  if (st != noErr) {
    /* Repli : deux tampons non entrelacés, désentrelacés dans le rappel. */
    fmt.mFormatFlags |= kAudioFormatFlagIsNonInterleaved;
    fmt.mBytesPerFrame = sizeof(float);
    fmt.mBytesPerPacket = sizeof(float);
    st = AudioUnitSetProperty(g_audio.unite, kAudioUnitProperty_StreamFormat,
                              kAudioUnitScope_Input, 0, &fmt, sizeof fmt);
    if (st != noErr) {
      erreur("audio", "format float32 stéréo refusé par l'unité de sortie "
                      "(%d)",
             (int)st);
      return TRAMES_AUDIO_STATUT_FORMAT;
    }
    g_audio.non_entrelace = 1;
    journal("audio", "format entrelacé refusé : repli sur deux tampons non "
                     "entrelacés");
  }

  AURenderCallbackStruct rappel;
  rappel.inputProc = audio_rendre;
  rappel.inputProcRefCon = NULL;
  st = AudioUnitSetProperty(g_audio.unite, kAudioUnitProperty_SetRenderCallback,
                            kAudioUnitScope_Input, 0, &rappel, sizeof rappel);
  if (st != noErr) {
    erreur("audio", "rappel de rendu refusé (%d)", (int)st);
    return TRAMES_AUDIO_STATUT_INTERNE;
  }

  st = AudioUnitInitialize(g_audio.unite);
  if (st != noErr) {
    erreur("audio", "initialisation de l'unité de sortie impossible (%d)",
           (int)st);
    return TRAMES_AUDIO_STATUT_INTERNE;
  }
  g_audio.initialisee = 1;

  st = AudioOutputUnitStart(g_audio.unite);
  if (st != noErr) {
    erreur("audio", "démarrage de la sortie audio impossible (%d)", (int)st);
    audio_arreter_unite();
    return TRAMES_AUDIO_STATUT_INTERNE;
  }
  g_audio.demarre = 1;
  return TRAMES_AUDIO_STATUT_OK;
}

/* ------------------------------------------------------------------ */
/* Écriture des trames audio                                           */

static int audio_envoyer_trame(uint8_t type, const uint8_t *corps,
                               uint16_t longueur)
{
  uint8_t trame[TRAMES_ENTETE_TAILLE + TRAMES_AUDIO_DEVICE_TAILLE_MIN +
                 TRAMES_AUDIO_NOM_MAX];
  if (longueur > TRAMES_AUDIO_DEVICE_TAILLE_MIN + TRAMES_AUDIO_NOM_MAX)
    return -1;
  const int n = trame_encoder(trame, sizeof trame, type, 0, corps, longueur);
  if (n < 0)
    return -1;
  return ecrire_tout(g_audio.client_fd, trame, (size_t)n);
}

/* ------------------------------------------------------------------ */
/* Fichier anneau partagé : c'est nous qui le créons, le possédons      */

static int audio_preparer_anneau(void)
{
  const size_t total =
      sizeof(struct anneau_entete) + (size_t)ANNEAU_AUDIO_CAPACITE_MAX *
                                         OCTETS_TRAME;
  /* O_TRUNC récupère un fichier laissé par un assistant tué par SIGKILL. */
  const int fd = open(g_audio.chemin_pcm, O_RDWR | O_CREAT | O_TRUNC, 0600);
  if (fd < 0) {
    erreur("audio", "ouverture de %s : %s", g_audio.chemin_pcm,
           strerror(errno));
    return -1;
  }
  if (fchmod(fd, 0600) < 0)
    erreur("audio", "fchmod %s : %s", g_audio.chemin_pcm, strerror(errno));
  if (ftruncate(fd, (off_t)total) < 0) {
    erreur("audio", "ftruncate de %s : %s", g_audio.chemin_pcm,
           strerror(errno));
    close(fd);
    return -1;
  }
  void *p = mmap(NULL, total, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  const int e = errno;
  close(fd);
  if (p == MAP_FAILED) {
    errno = e;
    erreur("audio", "mmap de %s : %s", g_audio.chemin_pcm, strerror(errno));
    return -1;
  }
  g_audio.anneau = (struct anneau_entete *)p;
  g_audio.taille_anneau = total;
  if (anneau_initialiser(g_audio.anneau, CANAUX, (uint32_t)OCTETS_TRAME, 48000,
                         512, ANNEAU_AUDIO_CAPACITE_MAX, 1) != 0) {
    erreur("audio", "en-tête d'anneau non initialisable");
    munmap(g_audio.anneau, g_audio.taille_anneau);
    g_audio.anneau = NULL;
    g_audio.taille_anneau = 0;
    return -1;
  }
  g_audio.capacite = ANNEAU_AUDIO_CAPACITE_MAX;
  g_audio.pcm_proprietaire = 1;
  journal("audio", "anneau créé : %s (%zu octets, capacité %u trames)",
          g_audio.chemin_pcm, total, (unsigned)ANNEAU_AUDIO_CAPACITE_MAX);
  return 0;
}

/* ------------------------------------------------------------------ */
/* Session avec un client organum (audio)                              */

static void audio_fermer_client(int adieu)
{
  if (g_audio.etat == AUDIO_AUCUN)
    return;
  if (adieu && g_audio.etat == AUDIO_CONNECTE && g_audio.client_fd >= 0)
    audio_envoyer_trame(TRAMES_AUDIO_TYPE_BYE, NULL, 0);
  if (g_audio.client_fd >= 0) {
    close(g_audio.client_fd);
    g_audio.client_fd = -1;
  }
  g_audio.etat = AUDIO_AUCUN;
  g_audio.debut = 0;
  g_audio.fin = 0;
  /* Plus personne ne produit : arrêter la lecture évite de brasser du
     silence. Le prochain AUDIO_CONFIG redémarrera l'unité. Le domaine MIDI
     n'est pas concerné. */
  if (g_audio.anneau != NULL)
    atomic_store_explicit(&g_audio.anneau->arret, 1, memory_order_release);
  audio_arreter_unite();
  journal("audio", "client déconnecté");
}

static uint8_t audio_appliquer_config(const struct audio_config_vue *cfg)
{
  if (g_audio.anneau == NULL)
    return TRAMES_AUDIO_STATUT_INTERNE;
  /* L'assistant possède l'en-tête, mais un fichier ou un mappage incohérent
     ne doit jamais être utilisé en silence : un désaccord de version est un
     refus explicite (statut 3), pas une session qui ne produit rien. */
  if (g_audio.anneau->magie != ANNEAU_AUDIO_MAGIE ||
      g_audio.anneau->version != ANNEAU_AUDIO_VERSION) {
    erreur("audio", "en-tête d'anneau incompatible (magie 0x%08x, version %u, "
                    "attendue %u)",
           (unsigned)g_audio.anneau->magie, (unsigned)g_audio.anneau->version,
           (unsigned)ANNEAU_AUDIO_VERSION);
    return TRAMES_AUDIO_STATUT_CONFIG;
  }
  if (cfg->format != TRAMES_AUDIO_FORMAT_FLOAT32_ENTRELACE ||
      cfg->canaux != CANAUX ||
      cfg->octets != cfg->capacite * (uint32_t)OCTETS_TRAME)
    return TRAMES_AUDIO_STATUT_FORMAT;
  if (cfg->taux < TAUX_MIN || cfg->taux > TAUX_MAX)
    return TRAMES_AUDIO_STATUT_FORMAT;
  if (cfg->periode == 0 || cfg->periode > cfg->capacite ||
      cfg->capacite < ANNEAU_AUDIO_CAPACITE_MIN ||
      cfg->capacite > ANNEAU_AUDIO_CAPACITE_MAX ||
      (cfg->capacite & (cfg->capacite - 1u)) != 0)
    return TRAMES_AUDIO_STATUT_CONFIG;
  if (g_audio.anneau == NULL)
    return TRAMES_AUDIO_STATUT_INTERNE;

  struct sortie s;
  if (!audio_interroger_sortie(&s)) {
    /* Machine sans carte son (VM de test) : refus explicite, statut 2. */
    if (g_audio.demarre) {
      audio_arreter_unite();
      atomic_store_explicit(&g_audio.anneau->arret, 1, memory_order_release);
    }
    return TRAMES_AUDIO_STATUT_AUCUNE_SORTIE;
  }

  /* Changement de taux à chaud, ou reprise après une perte : on arrête,
     on réécrit l'en-tête, on reformate, on initialise et on relance. */
  audio_arreter_unite();
  if (anneau_initialiser(g_audio.anneau, CANAUX, (uint32_t)OCTETS_TRAME,
                         cfg->taux, cfg->periode, cfg->capacite,
                         cfg->generation) != 0)
    return TRAMES_AUDIO_STATUT_CONFIG;
  g_audio.capacite = cfg->capacite;
  g_audio.taux = cfg->taux;
  g_audio.periode = cfg->periode;

  const uint8_t statut = audio_preparer_unite(cfg->taux);
  if (statut != TRAMES_AUDIO_STATUT_OK) {
    atomic_store_explicit(&g_audio.anneau->arret, 1, memory_order_release);
    audio_arreter_unite();
    return statut;
  }
  journal("audio", "sortie configurée : %s, %u Hz, %u canal(aux), %s", s.nom,
          (unsigned)cfg->taux, (unsigned)cfg->canaux,
          g_audio.non_entrelace ? "non entrelacé" : "entrelacé");
  return TRAMES_AUDIO_STATUT_OK;
}

static void audio_repondre_config(const uint8_t *corps, uint16_t longueur)
{
  struct audio_config_vue cfg;
  if (audio_config_decoder(corps, longueur, &cfg) != 0) {
    erreur("audio", "AUDIO_CONFIG malformé : trame ignorée");
    return;
  }
  journal("audio",
          "CONFIG reçue : génération=%u taux=%u période=%u canaux=%u "
          "format=%u capacité=%u octets=%u",
          cfg.generation, cfg.taux, cfg.periode, cfg.canaux, cfg.format,
          cfg.capacite, cfg.octets);

  const uint8_t statut = audio_appliquer_config(&cfg);

  struct audio_ack_vue ack;
  memset(&ack, 0, sizeof ack);
  ack.statut = statut;
  ack.generation = cfg.generation;
  ack.taux = cfg.taux;
  ack.periode = cfg.periode;
  ack.capacite = g_audio.capacite;
  uint8_t corps_ack[TRAMES_AUDIO_ACK_TAILLE];
  const int n = audio_ack_encoder(corps_ack, sizeof corps_ack, &ack);
  if (n < 0 || audio_envoyer_trame(TRAMES_AUDIO_TYPE_ACK, corps_ack,
                                   (uint16_t)n) < 0) {
    erreur("audio", "acquittement audio impossible à envoyer");
    audio_fermer_client(0);
    return;
  }
  journal("audio", "ACK envoyé : statut=%u taux=%u période=%u capacité=%u",
          statut, cfg.taux, cfg.periode, g_audio.capacite);
  if (statut != TRAMES_AUDIO_STATUT_OK)
    return;

  struct sortie s;
  struct audio_device_vue dev;
  memset(&dev, 0, sizeof dev);
  memset(&s, 0, sizeof s);
  if (audio_interroger_sortie(&s)) {
    dev.nom_len = (uint8_t)strlen(s.nom);
    if (dev.nom_len > TRAMES_AUDIO_NOM_MAX)
      dev.nom_len = TRAMES_AUDIO_NOM_MAX;
    dev.nom = (const uint8_t *)s.nom;
    dev.taux_natif = s.taux;
    dev.latence_us = s.latence_us;
  }
  uint8_t corps_dev[TRAMES_AUDIO_DEVICE_TAILLE_MIN + TRAMES_AUDIO_NOM_MAX];
  const int nd = audio_device_encoder(corps_dev, sizeof corps_dev, &dev);
  if (nd > 0 && audio_envoyer_trame(TRAMES_AUDIO_TYPE_DEVICE, corps_dev,
                                    (uint16_t)nd) < 0)
    journal("audio", "AUDIO_DEVICE perdu (écriture impossible)");
}

/* Traite toutes les trames complètes déjà présentes. Renvoie 0, ou -1 si la
   session s'arrête. */
static int audio_traiter_entree(void)
{
  for (;;) {
    struct trame_vue vue;
    size_t consommes = 0;
    const int code =
        trame_decoder(&g_audio.decodeur, g_audio.entree + g_audio.debut,
                      (size_t)(g_audio.fin - g_audio.debut), &vue, &consommes);
    if (code < 0) {
      erreur("audio", "longueur de trame supérieure à max_frame : fermeture");
      audio_fermer_client(0);
      return -1;
    }
    if (code == 0) {
      g_audio.debut = g_audio.fin = 0;
      return 0;
    }
    g_audio.debut += (int)consommes;

    switch (vue.type) {
    case TRAMES_AUDIO_TYPE_CONFIG:
      audio_repondre_config(vue.corps, vue.longueur);
      if (g_audio.etat == AUDIO_AUCUN)
        return -1;
      break;
    case TRAMES_AUDIO_TYPE_PING:
      if (audio_envoyer_trame(TRAMES_AUDIO_TYPE_PONG, NULL, 0) < 0) {
        audio_fermer_client(0);
        return -1;
      }
      break;
    case TRAMES_AUDIO_TYPE_STOP:
      journal("audio", "AUDIO_STOP reçu d'organum");
      break;
    case TRAMES_AUDIO_TYPE_BYE:
      journal("audio", "BYE reçu d'organum");
      audio_fermer_client(0);
      return -1;
    default:
      break; /* type inconnu : trame lue puis ignorée */
    }
    if (g_audio.debut == g_audio.fin)
      g_audio.debut = g_audio.fin = 0;
  }
}

static int audio_lire_client(void)
{
  if (g_audio.etat == AUDIO_AUCUN)
    return 0;
  if (g_audio.debut == g_audio.fin)
    g_audio.debut = g_audio.fin = 0;
  if (g_audio.fin >= (int)sizeof g_audio.entree) {
    erreur("audio", "tampon d'entrée saturé : fermeture");
    audio_fermer_client(0);
    return -1;
  }
  const ssize_t r = recv(g_audio.client_fd, g_audio.entree + g_audio.fin,
                         sizeof g_audio.entree - (size_t)g_audio.fin, 0);
  if (r == 0) {
    journal("audio", "fin de flux");
    audio_fermer_client(0);
    return -1;
  }
  if (r < 0) {
    if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)
      return 0;
    erreur("audio", "lecture de la socket : %s", strerror(errno));
    audio_fermer_client(0);
    return -1;
  }
  g_audio.fin += (int)r;
  return audio_traiter_entree();
}

/* Accepte un client et échange la poignée dans le délai le plus court
   possible : organum n'attend que 200 ms pour la réponse. */
static void audio_accepter_client(void)
{
  const int fd = accept(g_audio.ecoute, NULL, NULL);
  if (fd < 0) {
    if (errno != EINTR)
      erreur("audio", "accept : %s", strerror(errno));
    return;
  }

  if (g_audio.etat != AUDIO_AUCUN) {
    /* Une reconnexion d'organum arrive souvent dans le même tour de poll que
       la fin de flux de la connexion précédente : laisser une courte chance
       à cet EOF évite de refuser une reprise légitime. */
    struct pollfd p = {g_audio.client_fd, POLLIN, 0};
    if (poll(&p, 1, 20) > 0 &&
        (p.revents & (POLLIN | POLLHUP | POLLERR)))
      audio_lire_client();
  }

  if (g_audio.etat != AUDIO_AUCUN) {
    /* Un seul client. Le protocole audio n'a pas de statut « déjà un
       client » : on lit la poignée pour éviter un RST, on répond un statut
       interne puis on ferme. */
    uint8_t poignee[TRAMES_AUDIO_POIGNEE_TAILLE];
    uint8_t reponse[TRAMES_AUDIO_POIGNEE_TAILLE];
    lire_exact(fd, poignee, sizeof poignee, AUDIO_DELAI_POIGNEE);
    poignee_audio_encoder(reponse, TRAMES_AUDIO_STATUT_INTERNE,
                          AUDIO_MAX_FRAME);
    ecrire_tout(fd, reponse, sizeof reponse);
    close(fd);
    journal("audio", "deuxième client refusé (déjà un abonné)");
    return;
  }

  uint8_t poignee[TRAMES_AUDIO_POIGNEE_TAILLE];
  if (lire_exact(fd, poignee, sizeof poignee, AUDIO_DELAI_POIGNEE) != 0) {
    erreur("audio", "poignée de main non reçue dans le délai");
    close(fd);
    return;
  }
  struct poignee_vue vue;
  const int code = poignee_audio_decoder(poignee, &vue);
  uint8_t statut = TRAMES_AUDIO_STATUT_INTERNE;
  if (code == 1)
    statut = TRAMES_AUDIO_STATUT_OK;
  else if (code == -2)
    /* Version de protocole (donc de disposition de l'anneau) incompatible :
       refus explicite, jamais une session silencieuse. */
    statut = TRAMES_AUDIO_STATUT_CONFIG;

  uint8_t reponse[TRAMES_AUDIO_POIGNEE_TAILLE];
  poignee_audio_encoder(reponse, statut, AUDIO_MAX_FRAME);
  if (ecrire_tout(fd, reponse, sizeof reponse) < 0) {
    erreur("audio", "réponse de poignée de main impossible");
    close(fd);
    return;
  }
  if (statut != TRAMES_AUDIO_STATUT_OK) {
    journal("audio",
            "poignée refusée (code %d, statut %u, client version %u, "
            "attendue %u)",
            code, (unsigned)statut, (unsigned)vue.version,
            (unsigned)TRAMES_AUDIO_VERSION);
    close(fd);
    return;
  }

  g_audio.max_frame = vue.max_frame;
  if (g_audio.max_frame > AUDIO_MAX_FRAME)
    g_audio.max_frame = AUDIO_MAX_FRAME;
  trame_decodeur_init(&g_audio.decodeur, g_audio.max_frame);
  g_audio.client_fd = fd;
  g_audio.debut = 0;
  g_audio.fin = 0;
  g_audio.etat = AUDIO_CONNECTE;
  journal("audio", "poignée acceptée (max_frame %u)", g_audio.max_frame);
}

/* ------------------------------------------------------------------ */
/* Surveillance du périphérique par défaut                             */

static OSStatus audio_sur_peripherique(
    AudioObjectID objet, UInt32 n, const AudioObjectPropertyAddress *adresses,
    void *contexte)
{
  (void)objet;
  (void)n;
  (void)adresses;
  (void)contexte;
  atomic_store_explicit(&g_audio.peripherique_change, 1, memory_order_release);
  return noErr;
}

/* Perte du périphérique en cours de jeu : arrêt de la lecture et AUDIO_STOP,
   sans quitter. Organum verra arret dans l'en-tête, fermera, puis réessaiera
   comme après un démarrage sans assistant. Le domaine MIDI continue : ni les
   connexions CoreMIDI, ni la socket MIDI ne sont touchées. */
static void audio_verifier_peripherique(void)
{
  if (g_audio.ecoute < 0)
    return;
  const time_t maintenant = time(NULL);
  const int signale = atomic_exchange_explicit(
      &g_audio.peripherique_change, 0, memory_order_acq_rel);
  if (!signale && maintenant == g_audio.derniere_verif)
    return;
  g_audio.derniere_verif = maintenant;

  if (!g_audio.demarre)
    return;
  if (audio_interroger_sortie(NULL))
    return;

  erreur("audio", "périphérique de sortie perdu : lecture arrêtée");
  if (g_audio.anneau != NULL)
    atomic_store_explicit(&g_audio.anneau->arret, 1, memory_order_release);
  struct audio_stop_vue stop;
  stop.raison = RAISON_PERIPHERIQUE_PERDU;
  uint8_t corps[TRAMES_AUDIO_STOP_TAILLE];
  const int n = audio_stop_encoder(corps, sizeof corps, &stop);
  if (n > 0 && g_audio.client_fd >= 0 &&
      audio_envoyer_trame(TRAMES_AUDIO_TYPE_STOP, corps, (uint16_t)n) < 0)
    journal("audio", "AUDIO_STOP perdu (écriture impossible)");
  audio_arreter_unite();
}

/* ------------------------------------------------------------------ */
/* Diagnostic --liste (audio)                                          */

static int audio_lister_sortie(void)
{
  struct sortie s;
  if (!audio_interroger_sortie(&s)) {
    printf("organum-helper : audio : aucune sortie audio disponible : aucun "
           "périphérique de sortie par défaut.\n");
    printf("organum-helper : audio : une machine virtuelle sans carte son n'en "
           "a aucun ; organum restera alors en audio dégradé, sans planter.\n");
    printf("organum-helper : audio : sur un Mac réel, vérifiez « Réglages "
           "Système → Son → Sortie » ou branchez un périphérique USB.\n");
    return 1;
  }
  printf("organum-helper : audio : sortie par défaut : « %s »\n", s.nom);
  printf("organum-helper : audio :   taux nominal %u Hz, %u canal(aux) de "
         "sortie, latence estimée %u µs\n",
         (unsigned)s.taux, (unsigned)s.canaux, (unsigned)s.latence_us);
  printf("organum-helper : audio :   l'anneau sera <chemin socket>.pcm, %u "
         "trames float32 entrelacées\n",
         (unsigned)ANNEAU_AUDIO_CAPACITE_MAX);
  return 0;
}

/* ------------------------------------------------------------------ */
/* Arrêt et démarrage du domaine audio                                 */

static void audio_arreter(void)
{
  audio_detruire_unite();
  audio_fermer_client(0);
  if (g_audio.anneau != NULL) {
    munmap(g_audio.anneau, g_audio.taille_anneau);
    g_audio.anneau = NULL;
    g_audio.taille_anneau = 0;
  }
  if (g_audio.pcm_proprietaire) {
    if (unlink(g_audio.chemin_pcm) < 0 && errno != ENOENT)
      erreur("audio", "unlink %s : %s", g_audio.chemin_pcm,
             strerror(errno));
    g_audio.pcm_proprietaire = 0;
  }
  if (g_audio.ecoute >= 0) {
    close(g_audio.ecoute);
    g_audio.ecoute = -1;
  }
  if (g_audio.proprietaire) {
    if (unlink(g_audio.chemin) < 0 && errno != ENOENT)
      erreur("audio", "unlink %s : %s", g_audio.chemin, strerror(errno));
    g_audio.proprietaire = 0;
  }
}

/* Démarre le domaine audio : socket d'écoute puis anneau. Un échec laisse
   simplement l'audio indisponible, le MIDI continue. Renvoie 0, -3 si un autre
   assistant écoute déjà, -1 sur autre échec. */
static int audio_demarrer(void)
{
  const int ecoute = ouvrir_ecoute("audio", g_audio.chemin);
  if (ecoute < 0)
    return ecoute == -3 ? -3 : -1;
  g_audio.ecoute = ecoute;
  g_audio.proprietaire = 1;

  /* L'anneau vient après la sonde : un assistant déjà vivant ne doit jamais
     voir son .pcm tronqué par un second venu. */
  if (audio_preparer_anneau() != 0) {
    erreur("audio", "anneau partagé indisponible : audio désactivé, le MIDI "
                    "continue");
    audio_arreter();
    return -1;
  }

  journal("audio", "écoute sur %s", g_audio.chemin);

  /* Un changement de périphérique par défaut se voit par ce rappel ; la
     boucle revérifie aussi une fois par seconde. */
  AudioObjectPropertyAddress adresse = {
      kAudioHardwarePropertyDefaultOutputDevice,
      kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
  if (AudioObjectAddPropertyListener(kAudioObjectSystemObject, &adresse,
                                     audio_sur_peripherique, NULL) != noErr)
    journal("audio", "surveillance du périphérique par défaut indisponible");

  struct sortie s;
  if (!audio_interroger_sortie(&s))
    erreur("audio", "aucune sortie audio disponible pour l'instant : les "
                    "demandes d'organum seront refusées (statut 2) jusqu'à "
                    "son apparition");
  else
    journal("audio", "sortie par défaut : %s (%u Hz, %u canal(aux))", s.nom,
            (unsigned)s.taux, (unsigned)s.canaux);
  return 0;
}

/* ================================================================== */
/* Diagnostic combiné et principal                                     */
/* ================================================================== */

static void aide(const char *programme)
{
  printf("Usage : %s [--socket-midi CHEMIN] [--socket-audio CHEMIN]\n"
         "          [--verbose] [--liste]\n\n"
         "  --socket-midi CHEMIN   force le chemin de la socket MIDI\n"
         "  --socket-audio CHEMIN  force le chemin de la socket audio\n"
         "  --verbose              journal détaillé sur la sortie d'erreur\n"
         "  --liste                affiche la sortie audio par défaut et les\n"
         "                         sources CoreMIDI, puis sort (code 0 si tout\n"
         "                         va bien, 1 si un domaine manque)\n\n"
         "Sans option, les chemins sont $TMPDIR/organum-midi-<uid>.sock et\n"
         "$TMPDIR/organum-audio-<uid>.sock (ou /tmp/…). L'anneau audio est\n"
         "<socket audio>.pcm. La sortie est toujours le périphérique système\n"
         "par défaut.\n",
         programme);
}

static int lister_tout(void)
{
  int code = 0;
  if (audio_lister_sortie() != 0)
    code = 1;
  if (midi_lister_sources() != 0)
    code = 1;
  return code;
}

/* Remplit un chemin depuis --socket-* ou le résout par défaut. Renvoie 0 ou
   -1 (chemin invalide). */
static int choisir_chemin(const char *argument, const char *variable,
                          const char *nom, char *sortie, size_t capacite)
{
  if (argument != NULL) {
    const size_t taille = strlen(argument);
    if (taille == 0 || taille >= capacite) {
      erreur("commun", "chemin %s invalide", nom);
      return -1;
    }
    memcpy(sortie, argument, taille + 1);
    return 0;
  }
  if (trame_chemin_socket_nom(getenv(variable), getenv("TMPDIR"),
                              (unsigned long)getuid(), nom, sortie,
                              capacite) != 0) {
    erreur("commun", "chemin de socket %s par défaut invalide (trop long)",
           nom);
    return -1;
  }
  return 0;
}

int main(int argc, char **argv)
{
  const char *socket_midi = NULL;
  const char *socket_audio = NULL;
  int liste = 0;

  for (int i = 1; i < argc; ++i) {
    if (strcmp(argv[i], "--socket-midi") == 0 && i + 1 < argc) {
      socket_midi = argv[++i];
    } else if (strcmp(argv[i], "--socket-audio") == 0 && i + 1 < argc) {
      socket_audio = argv[++i];
    } else if (strcmp(argv[i], "--verbose") == 0) {
      g_verbose = 1;
    } else if (strcmp(argv[i], "--liste") == 0) {
      liste = 1;
    } else if (strcmp(argv[i], "--aide") == 0 || strcmp(argv[i], "-h") == 0) {
      aide(argv[0]);
      return 0;
    } else {
      erreur("commun", "argument inconnu « %s »", argv[i]);
      aide(argv[0]);
      return 2;
    }
  }

  if (choisir_chemin(socket_midi, "ORGANUM_MIDI_SOCKET", "midi", g_midi.chemin,
                     sizeof g_midi.chemin) != 0)
    return 2;
  if (choisir_chemin(socket_audio, "ORGANUM_AUDIO_SOCKET", "audio",
                     g_audio.chemin, sizeof g_audio.chemin) != 0)
    return 2;

  if (liste)
    return lister_tout();

  const size_t n = strlen(g_audio.chemin);
  if (n + sizeof ".pcm" > sizeof g_audio.chemin_pcm) {
    erreur("audio", "chemin de socket trop long pour le fichier anneau");
    return 2;
  }
  memcpy(g_audio.chemin_pcm, g_audio.chemin, n);
  memcpy(g_audio.chemin_pcm + n, ".pcm", sizeof ".pcm");

  signal(SIGINT, sur_signal);
  signal(SIGTERM, sur_signal);
  signal(SIGPIPE, SIG_IGN);

  g_midi.ecoute = -1;
  g_midi.client_fd = -1;
  g_midi.etat = MIDI_AUCUN;
  g_midi.max_frame = MIDI_MAX_FRAME;
  g_audio.ecoute = -1;
  g_audio.client_fd = -1;
  g_audio.etat = AUDIO_AUCUN;
  g_audio.max_frame = AUDIO_MAX_FRAME;
  atomic_init(&g_audio.peripherique_change, 0);

  /* Les deux domaines démarrent séparément. Un échec de l'un n'empêche jamais
     l'autre de servir ; seul un second assistant vivant (code 3) fait sortir
     tout le processus, pour ne pas partager une socket avec lui. */
  const int audio_statut = audio_demarrer();
  if (audio_statut == -3) {
    audio_arreter();
    return 3;
  }
  if (audio_statut != 0)
    journal("audio", "domaine audio indisponible ; le MIDI continue");

  const int midi_statut = midi_demarrer();
  if (midi_statut == -3) {
    audio_arreter();
    return 3;
  }
  if (midi_statut != 0)
    journal("midi", "domaine MIDI indisponible ; l'audio continue");

  if (!g_midi.actif && g_audio.ecoute < 0) {
    erreur("commun", "ni le MIDI ni l'audio ne sont disponibles");
    return 1;
  }

  while (!g_arret) {
    midi_servir();
    audio_verifier_peripherique();

    struct pollfd p[4];
    int quoi[4];
    nfds_t nfds = 0;

    if (g_midi.ecoute >= 0) {
      p[nfds].fd = g_midi.ecoute;
      p[nfds].events = POLLIN;
      p[nfds].revents = 0;
      quoi[nfds++] = 1;
    }
    if (g_midi.etat != MIDI_AUCUN && g_midi.client_fd >= 0) {
      p[nfds].fd = g_midi.client_fd;
      p[nfds].events = POLLIN;
      p[nfds].revents = 0;
      quoi[nfds++] = 2;
    }
    if (g_audio.ecoute >= 0) {
      p[nfds].fd = g_audio.ecoute;
      p[nfds].events = POLLIN;
      p[nfds].revents = 0;
      quoi[nfds++] = 3;
    }
    if (g_audio.etat != AUDIO_AUCUN && g_audio.client_fd >= 0) {
      p[nfds].fd = g_audio.client_fd;
      p[nfds].events = POLLIN;
      p[nfds].revents = 0;
      quoi[nfds++] = 4;
    }

    const int r = poll(p, nfds, DELAI_POLL);
    if (r < 0) {
      if (errno == EINTR)
        continue;
      erreur("commun", "poll : %s", strerror(errno));
      break;
    }
    if (r == 0)
      continue;

    for (nfds_t i = 0; i < nfds; ++i) {
      if (!(p[i].revents & (POLLIN | POLLHUP | POLLERR)))
        continue;
      switch (quoi[i]) {
      case 1:
        midi_accepter_client();
        break;
      case 2:
        midi_lire_client();
        break;
      case 3:
        audio_accepter_client();
        break;
      case 4:
        audio_lire_client();
        break;
      default:
        break;
      }
    }
  }

  journal("midi", "arrêt (%lu trame(s) jetée(s))", g_midi.trames_jetees);
  journal("audio", "arrêt demandé");
  midi_arreter();
  audio_arreter();
  return 0;
}
