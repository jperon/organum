/* Assistant CoreMIDI pour macOS, serveur de la socket MIDI d'organum.
 *
 * CoreMIDI n'est accessible que depuis un binaire Mach-O : cet assistant est
 * le seul à lui parler. Il crée la socket Unix décrite dans
 * PROTOCOLE-MIDI.md, s'abonne aux sources CoreMIDI et y écrit les messages
 * reçus en trames normalisées (codec trames_midi.h, partagé avec organum).
 *
 * Le rappel de lecture CoreMIDI tourne dans un fil Apple : il n'alloue pas,
 * ne bloque pas et ne fait aucun appel libc évitable. Les trames y sont
 * encodées dans un tampon de pile puis écrites sous mutex ; en cas d'EAGAIN
 * la trame est jetée et comptée, jamais attendue. Le fil principal possède
 * la socket d'écoute, la connexion, les abonnements et l'énumération.
 *
 * Licence : AGPL-3.0, comme le reste du dépôt (voir LICENSE.txt).
 */
#define _DARWIN_C_SOURCE 1

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
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#include "trames_midi.h"

#if defined(__clang__)
/* MIDIClientCreate et MIDIInputPortCreate (API historique, disponible depuis
   10.0) sont marquées obsolètes depuis macOS 11 au profit des variantes
   « WithProtocol », dont nous n'avons pas besoin. Le bruit est tué ici. */
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#endif

#define MAX_FRAME TRAMES_MIDI_MAX_FRAME_MAX
#define TAMPON_ENTREE 512
#define TAILLE_MORCEAU 128
#define DELAI_POLL 200
#define VERIF_SOURCES 1 /* secondes entre deux énumérations de secours */

enum etat_connexion { ETAT_AUCUN = 0, ETAT_POIGNEE, ETAT_CONNECTE };

struct source {
  MIDIEndpointRef endpoint;
  SInt32 unique;
  char nom[TRAMES_MIDI_NOM_MAX + 1];
  uint8_t id; /* identifiant du protocole, 1..255 */
  int vu;      /* usage interne à rafraichir_sources() */
  int connecte; /* port CoreMIDI connecté, fil principal seulement */
  _Atomic int actif;
};

static struct {
  MIDIClientRef client;
  MIDIPortRef port;
  int ecoute;
  int client_fd; /* protégé par g_ecriture */
  int proprietaire;
  char chemin[TRAMES_MIDI_SUN_PATH_MAX];
  int verbose;

  struct source sources[TRAMES_MIDI_PERIPHERIQUES_MAX];

  enum etat_connexion etat;
  uint8_t poignee[TRAMES_MIDI_POIGNEE_TAILLE];
  int poignee_recus;
  uint16_t max_frame;
  struct trame_decodeur decodeur;
  uint8_t entree[TAMPON_ENTREE];
  int debut, fin;

  time_t derniere_verif;
  volatile sig_atomic_t arret;
  /* PID du dernier client organum (LOCAL_PEERPID), lu par le gestionnaire
     de signal. Redbean, à l'arrêt d'organum, envoie SIGTERM à tout son groupe
     de processus : cet assistant ne doit pas mourir parce qu'il a été lancé
     dans le même groupe, tout en restant arrêtable par un SIGTERM direct. */
  volatile sig_atomic_t pid_organum;
  _Atomic int sources_changees;
  _Atomic int client_ko;
  _Atomic int sysex_ouvert;
  _Atomic unsigned long trames_jetees;
} g;

static pthread_mutex_t g_ecriture = PTHREAD_MUTEX_INITIALIZER;

/* Abonnements par identifiant du protocole, et non par source : organum
   raisonne lui aussi par identifiant, et un identifiant libéré puis réutilisé
   doit retrouver le même état. */
static _Atomic int g_abonnement[256];

/* ------------------------------------------------------------------ */
/* Journal                                                             */

static void journal(const char *format, ...)
{
  if (!g.verbose)
    return;
  va_list args;
  va_start(args, format);
  fputs("organum-midi : ", stderr);
  vfprintf(stderr, format, args);
  fputc('\n', stderr);
  va_end(args);
}

static void erreur(const char *format, ...)
{
  va_list args;
  va_start(args, format);
  fputs("organum-midi : ", stderr);
  vfprintf(stderr, format, args);
  fputc('\n', stderr);
  va_end(args);
}

/* ------------------------------------------------------------------ */
/* Écriture des trames                                                 */

static int ecrire_tout_locked(const uint8_t *octets, size_t n)
{
  int fd = g.client_fd;
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
      g.trames_jetees++;
      if (fait > 0)
        g.client_ko = 1;
      return -1;
    }
    if (w == 0)
      errno = EPIPE;
    g.client_ko = 1;
    return -1;
  }
  return 0;
}

static int envoyer_brut(const uint8_t *octets, size_t n)
{
  pthread_mutex_lock(&g_ecriture);
  int r = ecrire_tout_locked(octets, n);
  pthread_mutex_unlock(&g_ecriture);
  return r;
}

/* Trame de contrôle (ou MIDI court) : le corps tient dans TAILLE_MORCEAU. */
static int envoyer_trame(uint8_t type, uint8_t flags, const uint8_t *corps,
                         uint16_t longueur)
{
  uint8_t trame[TRAMES_MIDI_ENTETE_TAILLE + TAILLE_MORCEAU];
  if (longueur > TAILLE_MORCEAU)
    return -1;
  const int n =
      trame_encoder(trame, sizeof trame, type, flags, corps, longueur);
  if (n < 0)
    return -1;
  return envoyer_brut(trame, (size_t)n);
}

/* Écriture directe sur une socket fraîche (refus d'un deuxième client). */
static int ecrire_fd(int fd, const uint8_t *octets, size_t n)
{
  size_t fait = 0;
  while (fait < n) {
    ssize_t w = send(fd, octets + fait, n - fait, 0);
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

/* ------------------------------------------------------------------ */
/* Rappel CoreMIDI : aucun blocage, aucune allocation                  */

static void envoyer_midi_court(const uint8_t *corps, uint16_t longueur)
{
  if (!trame_midi_valide(corps, longueur))
    return;
  envoyer_trame(TRAMES_MIDI_TYPE_MIDI, 0, corps, longueur);
}

/* Morceau de SysEx : découpe [debut, fin) en tranches de TAILLE_MORCEAU.
   Le dernier morceau du message porte le drapeau 0, les autres SUITE. */
static void envoyer_sysex(const uint8_t *donnees, size_t n, size_t debut)
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
    size_t prendre = reste > TAILLE_MORCEAU ? TAILLE_MORCEAU : reste;
    const int suite = (pos + prendre < limite) || !trouve;
    envoyer_trame(TRAMES_MIDI_TYPE_SYSEX, suite ? TRAMES_MIDI_FLAG_SUITE : 0,
                  donnees + pos, (uint16_t)prendre);
    pos += prendre;
  }
  g.sysex_ouvert = !trouve;
}

static void traiter_paquet(const uint8_t *d, size_t n)
{
  size_t i = 0;

  /* Un SysEx commencé dans un paquet précédent reprend sans 0xF0. */
  if (g.sysex_ouvert) {
    size_t j = 0;
    while (j < n && d[j] != 0xF7)
      ++j;
    envoyer_sysex(d, j < n ? j + 1 : n, 0);
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
      envoyer_sysex(d, j < n ? j + 1 : n, i);
      i = j < n ? j + 1 : n;
      continue;
    }
    if (b == 0xF7) { /* fin de SysEx orpheline */
      g.sysex_ouvert = 0;
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
      envoyer_midi_court(d + i, (uint16_t)longueur);
    i += longueur;
  }
}

static void lire_midi(const MIDIPacketList *liste, void *refcon,
                      void *source_refcon)
{
  (void)refcon;
  const struct source *source = source_refcon;
  if (source == NULL || source->id == 0 ||
      !atomic_load(&g_abonnement[source->id]))
    return;

  const MIDIPacket *p = &liste->packet[0];
  for (UInt32 k = 0; k < liste->numPackets; ++k) {
    traiter_paquet(p->data, p->length);
    p = MIDIPacketNext(p);
  }
}

static void notifier(const MIDINotification *message, void *refcon)
{
  (void)message;
  (void)refcon;
  g.sources_changees = 1;
}

/* ------------------------------------------------------------------ */
/* Sources                                                             */

static void copier_nom(MIDIEndpointRef endpoint, char *sortie,
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

static int id_libre(void)
{
  for (int id = 1; id <= 255; ++id) {
    int pris = 0;
    for (int i = 0; i < TRAMES_MIDI_PERIPHERIQUES_MAX; ++i)
      if (atomic_load(&g.sources[i].actif) && g.sources[i].id == id) {
        pris = 1;
        break;
      }
    if (!pris)
      return id;
  }
  return 0;
}

static int trouver_source_par_id(uint8_t id)
{
  for (int i = 0; i < TRAMES_MIDI_PERIPHERIQUES_MAX; ++i)
    if (atomic_load(&g.sources[i].actif) && g.sources[i].id == id)
      return i;
  return -1;
}

/* Énumère les sources, connecte les nouvelles, déconnecte les disparues.
   Renvoie 1 si la liste publiée a changé. Fil principal uniquement. */
static int rafraichir_sources(void)
{
  int change = 0;
  for (int i = 0; i < TRAMES_MIDI_PERIPHERIQUES_MAX; ++i)
    g.sources[i].vu = 0;

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
      if (!atomic_load(&g.sources[j].actif))
        continue;
      if (g.sources[j].endpoint == endpoint ||
          (unique != 0 && g.sources[j].unique == unique)) {
        i = j;
        break;
      }
    }

    if (i < 0) {
      for (int j = 0; j < TRAMES_MIDI_PERIPHERIQUES_MAX; ++j)
        if (!atomic_load(&g.sources[j].actif)) {
          i = j;
          break;
        }
      if (i < 0) {
        journal("source ignorée : maximum de %d atteint",
                TRAMES_MIDI_PERIPHERIQUES_MAX);
        continue;
      }
      g.sources[i].endpoint = endpoint;
      g.sources[i].unique = unique;
      g.sources[i].id = (uint8_t)id_libre();
      g.sources[i].vu = 1;
      copier_nom(endpoint, g.sources[i].nom, sizeof g.sources[i].nom);
      atomic_store(&g.sources[i].actif, 1);
      const OSStatus st =
          MIDIPortConnectSource(g.port, endpoint, &g.sources[i]);
      g.sources[i].connecte = st == noErr;
      if (st != noErr)
        erreur("connexion de la source « %s » impossible (%d)",
               g.sources[i].nom, (int)st);
      else
        journal("source %u « %s » (unique %ld) connectée", g.sources[i].id,
                g.sources[i].nom, (long)unique);
      change = 1;
      continue;
    }

    /* Même identité, autre point d'entrée : rebrancher. */
    if (g.sources[i].endpoint != endpoint) {
      MIDIPortDisconnectSource(g.port, g.sources[i].endpoint);
      g.sources[i].endpoint = endpoint;
      if (unique != 0)
        g.sources[i].unique = unique;
      copier_nom(endpoint, g.sources[i].nom, sizeof g.sources[i].nom);
      g.sources[i].connecte =
          MIDIPortConnectSource(g.port, endpoint, &g.sources[i]) == noErr;
      if (!g.sources[i].connecte)
        erreur("reconnexion de la source « %s » impossible",
               g.sources[i].nom);
      change = 1;
    }

    /* Une source hors ligne à la découverte est réessayée à chaque tour. */
    if (!g.sources[i].connecte &&
        MIDIPortConnectSource(g.port, endpoint, &g.sources[i]) == noErr) {
      g.sources[i].connecte = 1;
      journal("source %u « %s » connectée", g.sources[i].id,
              g.sources[i].nom);
    }
    g.sources[i].vu = 1;
  }

  for (int i = 0; i < TRAMES_MIDI_PERIPHERIQUES_MAX; ++i) {
    if (!atomic_load(&g.sources[i].actif) || g.sources[i].vu)
      continue;
    MIDIPortDisconnectSource(g.port, g.sources[i].endpoint);
    g.sources[i].connecte = 0;
    atomic_store(&g.sources[i].actif, 0);
    journal("source %u « %s » retirée", g.sources[i].id, g.sources[i].nom);
    change = 1;
  }
  return change;
}

/* DEVICE_LIST complète, publiée après tout changement et à la connexion. */
static void envoyer_liste(void)
{
  uint8_t corps[1 + TRAMES_MIDI_PERIPHERIQUES_MAX *
                        (3 + TRAMES_MIDI_NOM_MAX)];
  size_t i = 1;
  unsigned long n = 0;
  for (int k = 0; k < TRAMES_MIDI_PERIPHERIQUES_MAX; ++k) {
    if (!atomic_load(&g.sources[k].actif) || g.sources[k].endpoint == 0)
      continue;
    if (n >= TRAMES_MIDI_PERIPHERIQUES_MAX)
      break;
    size_t longueur = strlen(g.sources[k].nom);
    if (longueur > TRAMES_MIDI_NOM_MAX)
      longueur = TRAMES_MIDI_NOM_MAX;
    corps[i++] = g.sources[k].id;
    corps[i++] = TRAMES_MIDI_CAPACITE_SOURCE;
    corps[i++] = (uint8_t)longueur;
    memcpy(corps + i, g.sources[k].nom, longueur);
    i += longueur;
    ++n;
  }
  corps[0] = (uint8_t)n;

  uint8_t trame[TRAMES_MIDI_ENTETE_TAILLE + sizeof corps];
  const int t = trame_encoder(trame, sizeof trame,
                              TRAMES_MIDI_TYPE_DEVICE_LIST, 0, corps,
                              (uint16_t)i);
  if (t < 0) {
    erreur("DEVICE_LIST trop grande");
    return;
  }
  if (envoyer_brut(trame, (size_t)t) < 0)
    journal("DEVICE_LIST perdue (écriture impossible)");
  else
    journal("DEVICE_LIST publiée (%lu source(s))", n);
}

/* ------------------------------------------------------------------ */
/* Connexion organum                                                   */

static void fermer_client_adieu(int adieu)
{
  if (g.etat == ETAT_AUCUN)
    return;
  if (adieu && g.etat == ETAT_CONNECTE)
    envoyer_trame(TRAMES_MIDI_TYPE_BYE, 0, NULL, 0);

  pthread_mutex_lock(&g_ecriture);
  if (g.client_fd >= 0)
    close(g.client_fd);
  g.client_fd = -1;
  pthread_mutex_unlock(&g_ecriture);

  for (int i = 0; i < 256; ++i)
    atomic_store(&g_abonnement[i], 0);

  g.etat = ETAT_AUCUN;
  g.poignee_recus = 0;
  g.debut = 0;
  g.fin = 0;
  g.sysex_ouvert = 0;
  g.client_ko = 0;
  journal("client déconnecté");
}

static void fermer_client(void)
{
  fermer_client_adieu(1);
}

static void accepter_client(void)
{
  const int fd = accept(g.ecoute, NULL, NULL);
  if (fd < 0) {
    if (errno != EINTR)
      erreur("accept : %s", strerror(errno));
    return;
  }

#if defined(SOL_LOCAL) && defined(LOCAL_PEERPID)
  {
    pid_t pair = 0;
    socklen_t taille = (socklen_t)sizeof pair;
    if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pair, &taille) == 0)
      g.pid_organum = (sig_atomic_t)pair;
  }
#endif

  if (g.etat != ETAT_AUCUN) {
    uint8_t reponse[TRAMES_MIDI_POIGNEE_TAILLE];
    poignee_encoder(reponse, TRAMES_MIDI_STATUT_CLIENT, MAX_FRAME);
    ecrire_fd(fd, reponse, sizeof reponse);
    close(fd);
    journal("deuxième client refusé (déjà un abonné)");
    return;
  }

  const int drapeaux = fcntl(fd, F_GETFL, 0);
  if (drapeaux >= 0)
    fcntl(fd, F_SETFL, drapeaux | O_NONBLOCK);

  pthread_mutex_lock(&g_ecriture);
  g.client_fd = fd;
  pthread_mutex_unlock(&g_ecriture);

  g.etat = ETAT_POIGNEE;
  g.poignee_recus = 0;
  g.debut = 0;
  g.fin = 0;
  g.sysex_ouvert = 0;
  g.client_ko = 0;
  journal("client connecté");
}

/* Traite ce qui est déjà dans g.entree. Renvoie -1 si la session s'arrête. */
static int traiter_entree(void)
{
  for (;;) {
    if (g.etat == ETAT_POIGNEE) {
      const size_t dispo = (size_t)(g.fin - g.debut);
      size_t prendre = (size_t)(TRAMES_MIDI_POIGNEE_TAILLE - g.poignee_recus);
      if (prendre > dispo)
        prendre = dispo;
      memcpy(g.poignee + g.poignee_recus, g.entree + g.debut, prendre);
      g.debut += (int)prendre;
      g.poignee_recus += (int)prendre;
      if (g.poignee_recus < TRAMES_MIDI_POIGNEE_TAILLE) {
        g.debut = g.fin = 0;
        return 0;
      }

      struct poignee_vue vue;
      const int code = poignee_decoder(g.poignee, &vue);
      uint8_t statut = TRAMES_MIDI_STATUT_INTERNE;
      if (code == 1)
        statut = TRAMES_MIDI_STATUT_OK;
      else if (code == -2)
        statut = TRAMES_MIDI_STATUT_VERSION;

      if (statut != TRAMES_MIDI_STATUT_OK) {
        uint8_t reponse[TRAMES_MIDI_POIGNEE_TAILLE];
        poignee_encoder(reponse, statut, MAX_FRAME);
        envoyer_brut(reponse, sizeof reponse);
        journal("poignée refusée (code %d)", code);
        fermer_client();
        return -1;
      }

      g.max_frame = vue.max_frame;
      if (g.max_frame > MAX_FRAME)
        g.max_frame = MAX_FRAME;
      trame_decodeur_init(&g.decodeur, g.max_frame);
      if (g.debut == g.fin)
        g.debut = g.fin = 0;
      g.etat = ETAT_CONNECTE;

      uint8_t reponse[TRAMES_MIDI_POIGNEE_TAILLE];
      poignee_encoder(reponse, TRAMES_MIDI_STATUT_OK, MAX_FRAME);
      if (envoyer_brut(reponse, sizeof reponse) < 0) {
        fermer_client();
        return -1;
      }
      journal("poignée acceptée (max_frame %u)", g.max_frame);
      envoyer_liste();
      continue;
    }

    struct trame_vue vue;
    size_t consommes = 0;
    const int code =
        trame_decoder(&g.decodeur, g.entree + g.debut,
                      (size_t)(g.fin - g.debut), &vue, &consommes);
    if (code < 0) {
      erreur("longueur de trame supérieure à max_frame : fermeture");
      fermer_client();
      return -1;
    }
    if (code == 0) {
      g.debut = g.fin = 0;
      return 0;
    }
    g.debut += (int)consommes;

    switch (vue.type) {
    case TRAMES_MIDI_TYPE_PING:
      envoyer_trame(TRAMES_MIDI_TYPE_PONG, 0, NULL, 0);
      break;
    case TRAMES_MIDI_TYPE_SUBSCRIBE:
      if (vue.longueur >= 2) {
        const int actif = vue.corps[1] != 0;
        atomic_store(&g_abonnement[vue.corps[0]], actif);
        const int i = trouver_source_par_id(vue.corps[0]);
        if (i >= 0)
          journal("source %u « %s » %s", g.sources[i].id,
                  g.sources[i].nom, actif ? "abonnée" : "désabonnée");
        else
          journal("source %u (absente) %s", vue.corps[0],
                  actif ? "abonnée" : "désabonnée");
      }
      break;
    case TRAMES_MIDI_TYPE_BYE:
      journal("BYE reçu d'organum");
      fermer_client_adieu(0);
      /* Fin de session normale : la socket d'écoute et les sources CoreMIDI
         restent en place, le prochain organum sera accepté. */
      return 0;
    default:
      break; /* type inconnu : trame lue puis ignorée */
    }
    if (g.debut == g.fin)
      g.debut = g.fin = 0;
  }
}

static int lire_client(void)
{
  if (g.etat == ETAT_AUCUN)
    return 0;
  if (g.debut == g.fin)
    g.debut = g.fin = 0;
  if (g.fin >= (int)sizeof g.entree) {
    erreur("tampon d'entrée saturé : fermeture");
    fermer_client();
    return -1;
  }

  const ssize_t r =
      recv(g.client_fd, g.entree + g.fin, sizeof g.entree - (size_t)g.fin, 0);
  if (r == 0) {
    journal("fin de flux");
    fermer_client();
    /* Le client est parti : on revient à l'écoute sans toucher aux sources
       CoreMIDI ni à la socket. */
    return 0;
  }
  if (r < 0) {
    if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)
      return 0;
    erreur("lecture de la socket : %s", strerror(errno));
    fermer_client();
    return -1;
  }
  g.fin += (int)r;
  return traiter_entree();
}

/* ------------------------------------------------------------------ */
/* Socket d'écoute                                                     */

/* Sonde la socket comme le prescrit le protocole : un assistant vivant garde
   la sienne, une socket périmée est remplacée. Renvoie -3 si un autre
   assistant écoute déjà. */
static int ouvrir_ecoute(const char *chemin)
{
  struct sockaddr_un adresse;
  memset(&adresse, 0, sizeof adresse);
  adresse.sun_family = AF_UNIX;
  memcpy(adresse.sun_path, chemin, strlen(chemin) + 1);

  const int sonde = socket(AF_UNIX, SOCK_STREAM, 0);
  if (sonde < 0) {
    erreur("socket : %s", strerror(errno));
    return -1;
  }
  if (connect(sonde, (struct sockaddr *)&adresse, sizeof adresse) == 0) {
    close(sonde);
    erreur("un autre assistant écoute déjà sur %s", chemin);
    return -3;
  }
  const int e = errno;
  close(sonde);
  if (e != ENOENT && e != ECONNREFUSED) {
    erreur("sonde de %s : %s", chemin, strerror(e));
    return -1;
  }

  umask(077);
  if (unlink(chemin) < 0 && errno != ENOENT) {
    erreur("unlink %s : %s", chemin, strerror(errno));
    return -1;
  }

  const int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) {
    erreur("socket : %s", strerror(errno));
    return -1;
  }
  if (bind(fd, (struct sockaddr *)&adresse, sizeof adresse) < 0) {
    erreur("bind %s : %s", chemin, strerror(errno));
    close(fd);
    return -1;
  }
  if (chmod(chemin, 0600) < 0)
    erreur("chmod %s : %s", chemin, strerror(errno));
  if (listen(fd, 1) < 0) {
    erreur("listen %s : %s", chemin, strerror(errno));
    close(fd);
    unlink(chemin);
    return -1;
  }
  return fd;
}

/* ------------------------------------------------------------------ */
/* Diagnostic --liste                                                  */

static int lister_sources(void)
{
  MIDIClientRef client = 0;
  const OSStatus st =
      MIDIClientCreate(CFSTR("organum-midi"), NULL, NULL, &client);
  if (st != noErr) {
    erreur("création du client CoreMIDI impossible (%d)", (int)st);
    return 1;
  }

  const ItemCount n = MIDIGetNumberOfSources();
  if (n == 0) {
    printf("organum-midi : aucune source MIDI détectée.\n");
    printf("organum-midi : ouvrez « Configuration audio et MIDI », menu "
           "Fenêtre → Afficher le studio MIDI,\n"
           "organum-midi : double-cliquez sur « IAC Driver » et cochez "
           "« Périphérique en ligne »,\n"
           "organum-midi : ou branchez un clavier MIDI USB.\n");
  } else {
    printf("organum-midi : %lu source(s) MIDI :\n", (unsigned long)n);
    for (ItemCount k = 0; k < n; ++k) {
      const MIDIEndpointRef endpoint = MIDIGetSource(k);
      SInt32 unique = 0;
      MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &unique);
      char nom[TRAMES_MIDI_NOM_MAX + 1];
      copier_nom(endpoint, nom, sizeof nom);
      printf("organum-midi :   unique %-10ld %s\n", (long)unique, nom);
    }
  }

  MIDIClientDispose(client);
  return 0;
}

/* ------------------------------------------------------------------ */
/* Arrêt                                                               */

static void arreter_assistant(void)
{
  g.arret = 1;
  fermer_client();
  for (int i = 0; i < TRAMES_MIDI_PERIPHERIQUES_MAX; ++i) {
    if (!atomic_load(&g.sources[i].actif))
      continue;
    if (g.port != 0)
      MIDIPortDisconnectSource(g.port, g.sources[i].endpoint);
    g.sources[i].connecte = 0;
    atomic_store(&g.sources[i].actif, 0);
  }
  if (g.port != 0)
    MIDIPortDispose(g.port);
  if (g.client != 0)
    MIDIClientDispose(g.client);
  if (g.ecoute >= 0)
    close(g.ecoute);
  if (g.proprietaire)
    unlink(g.chemin);
  g.port = 0;
  g.client = 0;
  g.ecoute = -1;
  g.proprietaire = 0;
}

static void sur_signal(int sig, siginfo_t *info, void *contexte)
{
  (void)contexte;
  /* Redbean tue son groupe de processus à l'arrêt d'organum. Si le SIGTERM
     vient précisément du client organum (kill(0, SIGTERM)), il ne vise pas
     cet assistant en tant que service : on l'ignore et on reste à l'écoute.
     Un SIGTERM direct (kill du PID, launchd, shell) a un autre émetteur et
     arrête normalement l'assistant. */
  if (sig == SIGTERM && info != NULL && g.pid_organum > 0 &&
      info->si_pid == (pid_t)g.pid_organum)
    return;
  g.arret = 1;
}

static void aide(const char *programme)
{
  printf("Usage : %s [--socket CHEMIN] [--verbose] [--liste]\n\n"
         "  --socket CHEMIN  force le chemin de la socket\n"
         "  --verbose        journal détaillé sur la sortie d'erreur\n"
         "  --liste          affiche les sources CoreMIDI et sort\n",
         programme);
}

/* ------------------------------------------------------------------ */
/* Principal                                                           */

int main(int argc, char **argv)
{
  const char *socket_arg = NULL;
  int liste = 0;

  for (int i = 1; i < argc; ++i) {
    if (strcmp(argv[i], "--socket") == 0 && i + 1 < argc) {
      socket_arg = argv[++i];
    } else if (strcmp(argv[i], "--verbose") == 0) {
      g.verbose = 1;
    } else if (strcmp(argv[i], "--liste") == 0) {
      liste = 1;
    } else if (strcmp(argv[i], "--aide") == 0 || strcmp(argv[i], "-h") == 0) {
      aide(argv[0]);
      return 0;
    } else {
      erreur("argument inconnu « %s »", argv[i]);
      aide(argv[0]);
      return 2;
    }
  }

  char chemin[TRAMES_MIDI_SUN_PATH_MAX];
  if (socket_arg != NULL) {
    const size_t taille = strlen(socket_arg);
    if (taille == 0 || taille >= sizeof chemin) {
      erreur("chemin --socket invalide");
      return 2;
    }
    memcpy(chemin, socket_arg, taille + 1);
  } else if (trame_chemin_socket(getenv("ORGANUM_MIDI_SOCKET"),
                                 getenv("TMPDIR"), (unsigned long)getuid(),
                                 chemin, sizeof chemin) != 0) {
    erreur("chemin de socket par défaut invalide (trop long)");
    return 2;
  }

  if (liste)
    return lister_sources();

  struct sigaction sa;
  memset(&sa, 0, sizeof sa);
  sa.sa_sigaction = sur_signal;
  sa.sa_flags = SA_SIGINFO;
  sigemptyset(&sa.sa_mask);
  sigaction(SIGINT, &sa, NULL);
  sigaction(SIGTERM, &sa, NULL);
  signal(SIGPIPE, SIG_IGN);

  g.ecoute = -1;
  g.client_fd = -1;
  g.etat = ETAT_AUCUN;
  g.max_frame = MAX_FRAME;

  const int ecoute = ouvrir_ecoute(chemin);
  if (ecoute < 0)
    return ecoute == -3 ? 3 : 1;
  g.ecoute = ecoute;
  g.proprietaire = 1;
  memcpy(g.chemin, chemin, strlen(chemin) + 1);

  if (MIDIClientCreate(CFSTR("organum-midi"), notifier, NULL, &g.client) !=
      noErr) {
    erreur("création du client CoreMIDI impossible");
    arreter_assistant();
    return 1;
  }
  if (MIDIInputPortCreate(g.client, CFSTR("organum-midi"), lire_midi, NULL,
                          &g.port) != noErr) {
    erreur("création du port d'entrée CoreMIDI impossible");
    arreter_assistant();
    return 1;
  }

  g.derniere_verif = time(NULL);
  journal("écoute sur %s", chemin);
  if (rafraichir_sources() == 0)
    journal("aucune source CoreMIDI pour l'instant");
  else
    journal("sources CoreMIDI présentes");

  while (!g.arret) {
    /* CoreMIDI ne livre ses notifications et n'actualise son cache de
       sources que sur le run loop du fil qui a créé le client. Sans ce
       pompage, une source branchée à chaud reste invisible malgré
       l'énumération de secours, et le rappel de lecture n'est jamais
       appelé. Le délai nul rend la main aussitôt : le fil continue de
       servir la socket avec son poll(). */
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.0, true);
    if (g.client_ko && g.etat != ETAT_AUCUN)
      fermer_client();

    const time_t maintenant = time(NULL);
    if (g.sources_changees || maintenant != g.derniere_verif) {
      g.sources_changees = 0;
      g.derniere_verif = maintenant;
      if (rafraichir_sources() && g.etat == ETAT_CONNECTE)
        envoyer_liste();
    }

    struct pollfd p[2];
    p[0].fd = g.ecoute;
    p[0].events = POLLIN;
    p[0].revents = 0;
    nfds_t nfds = 1;
    if (g.etat != ETAT_AUCUN) {
      p[1].fd = g.client_fd;
      p[1].events = POLLIN;
      p[1].revents = 0;
      nfds = 2;
    }

    const int r = poll(p, nfds, DELAI_POLL);
    if (r < 0) {
      if (errno == EINTR)
        continue;
      erreur("poll : %s", strerror(errno));
      break;
    }
    if (r == 0)
      continue;

    if (p[0].revents & POLLIN)
      accepter_client();
    if (nfds > 1 && p[1].fd >= 0 &&
        (p[1].revents & (POLLIN | POLLHUP | POLLERR)))
      lire_client();
  }

  journal("arrêt (%lu trame(s) jetée(s))", g.trames_jetees);
  arreter_assistant();
  return 0;
}
