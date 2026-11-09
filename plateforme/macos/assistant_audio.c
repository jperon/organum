/* Assistant CoreAudio pour macOS, serveur de la socket audio d'organum.
 *
 * CoreAudio n'est accessible que depuis un binaire Mach-O : cet assistant est
 * le seul à lui parler. Il crée la socket Unix et le fichier anneau `.pcm`
 * décrits dans PROTOCOLE-AUDIO.md, possède les deux, configure une AudioUnit
 * de sortie par défaut et joue, dans son rappel de rendu, les échantillons
 * float32 entrelacés déposés par organum dans l'anneau partagé.
 *
 * Le rappel de rendu tourne dans un fil Apple : il n'alloue pas, ne prend
 * aucun verrou, n'appelle ni printf ni aucune fonction libc bloquante. Il lit
 * l'anneau dans un tampon de pile borné, complète le manque par du silence
 * (l'anneau compte les underruns) et n'écrit que dans les tampons fournis par
 * CoreAudio. Le fil principal possède la socket, l'AudioUnit et l'anneau.
 *
 * L'AudioUnit est de type kAudioUnitType_Output / kAudioUnitSubType_
 * DefaultOutput : pas d'AudioQueue, donc pas de tampon interne
 * supplémentaire (une copie et de la latence en moins). Le format demandé
 * est float32 entrelacé au taux d'organum ; si l'unité le refuse, on se replie
 * sur deux tampons non entrelacés et le rappel désentrelace lui-même.
 *
 * Licence : AGPL-3.0, comme le reste du dépôt (voir LICENSE.txt).
 */
#define _DARWIN_C_SOURCE 1

#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
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

#define MAX_FRAME TRAMES_MAX_FRAME_MAX
#define TAMPON_ENTREE 512
#define DELAI_POLL 200 /* ms, période de la boucle principale */
#define DELAI_POIGNEE 150 /* ms, plus court que le délai d'organum (200 ms) */
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

enum etat_connexion { ETAT_AUCUN = 0, ETAT_CONNECTE };

struct sortie {
  AudioObjectID objet;
  char nom[TRAMES_AUDIO_NOM_MAX + 1];
  uint32_t taux;     /* taux nominal du périphérique, 0 si inconnu */
  uint32_t canaux;   /* canaux de sortie du périphérique */
  uint32_t latence_us;
};

static struct {
  int ecoute;
  int client_fd;
  int proprietaire; /* la socket est à nous : on la retire à l'arrêt */
  int pcm_proprietaire;
  char chemin[TRAMES_SUN_PATH_MAX];
  char chemin_pcm[TRAMES_SUN_PATH_MAX + 8];
  int verbose;

  struct anneau_entete *anneau;
  size_t taille_anneau;
  uint32_t capacite;

  AudioUnit unite;
  int initialisee;
  int demarre;
  int non_entrelace;
  uint32_t taux;
  uint32_t periode;

  enum etat_connexion etat;
  struct trame_decodeur decodeur;
  uint8_t entree[TAMPON_ENTREE];
  int debut, fin;
  uint16_t max_frame;

  _Atomic int peripherique_change;
  time_t derniere_verif;
} g;

static volatile sig_atomic_t arret_demande;

/* ------------------------------------------------------------------ */
/* Journal                                                             */

static void journal(const char *format, ...)
{
  if (!g.verbose)
    return;
  va_list args;
  va_start(args, format);
  fputs("organum-audio : ", stderr);
  vfprintf(stderr, format, args);
  fputc('\n', stderr);
  va_end(args);
}

static void erreur(const char *format, ...)
{
  va_list args;
  va_start(args, format);
  fputs("organum-audio : ", stderr);
  vfprintf(stderr, format, args);
  fputc('\n', stderr);
  va_end(args);
}

/* Horloge : binaire Mach-O compilé par le clang d'Apple, donc CLOCK_MONOTONIC
   est celui de la libc native. Il n'a pas le défaut de diviseur TSC de
   cosmocc sous XNU, et aucune durée « humaine » n'est mesurée ici de toute
   façon. */
static long long maintenant_ns(void)
{
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (long long)t.tv_sec * 1000000000LL + (long long)t.tv_nsec;
}

/* ------------------------------------------------------------------ */
/* Sortie audio : interrogation du périphérique par défaut              */

static int canaux_sortie(AudioObjectID device, uint32_t *canaux)
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

static void nom_sortie(AudioObjectID device, char *sortie, size_t capacite)
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

static uint32_t latence_us(AudioObjectID device, uint32_t taux)
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
static int interroger_sortie(struct sortie *s)
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
  if (!canaux_sortie(device, &canaux) || canaux == 0)
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
    nom_sortie(device, s->nom, sizeof s->nom);
    s->latence_us = latence_us(device, s->taux);
  }
  return 1;
}

/* ------------------------------------------------------------------ */
/* Rappel de rendu : aucun verrou, aucune allocation, aucun appel bloquant */

static OSStatus rendre(void *refcon, AudioUnitRenderActionFlags *drapeaux,
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
    if (g.anneau != NULL)
      lues = anneau_lire(g.anneau, melange, (size_t)bloc);
    if (lues < (size_t)bloc)
      memset(melange + lues * CANAUX, 0,
             ((size_t)bloc - lues) * OCTETS_TRAME);

    if (g.non_entrelace) {
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

static void arreter_unite(void)
{
  if (g.unite == 0)
    return;
  if (g.demarre) {
    AudioOutputUnitStop(g.unite);
    g.demarre = 0;
  }
  if (g.initialisee) {
    AudioUnitUninitialize(g.unite);
    g.initialisee = 0;
  }
}

static void detruire_unite(void)
{
  arreter_unite();
  if (g.unite != 0)
    AudioComponentInstanceDispose(g.unite);
  g.unite = 0;
}

/* Crée si besoin, formate, initialise et démarre l'unité de sortie.
   Renvoie un statut AUDIO_ACK. */
static uint8_t preparer_unite(uint32_t taux)
{
  if (g.unite == 0) {
    AudioComponentDescription desc;
    memset(&desc, 0, sizeof desc);
    desc.componentType = kAudioUnitType_Output;
    desc.componentSubType = kAudioUnitSubType_DefaultOutput;
    desc.componentManufacturer = kAudioUnitManufacturer_Apple;
    AudioComponent composant = AudioComponentFindNext(NULL, &desc);
    if (composant == NULL) {
      erreur("aucune unité de sortie CoreAudio (DefaultOutput)");
      return TRAMES_AUDIO_STATUT_AUCUNE_SORTIE;
    }
    const OSStatus st = AudioComponentInstanceNew(composant, &g.unite);
    if (st != noErr) {
      erreur("création de l'unité de sortie impossible (%d)", (int)st);
      g.unite = 0;
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

  g.non_entrelace = 0;
  OSStatus st = AudioUnitSetProperty(
      g.unite, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt,
      sizeof fmt);
  if (st != noErr) {
    /* Repli : deux tampons non entrelacés, désentrelacés dans le rappel. */
    fmt.mFormatFlags |= kAudioFormatFlagIsNonInterleaved;
    fmt.mBytesPerFrame = sizeof(float);
    fmt.mBytesPerPacket = sizeof(float);
    st = AudioUnitSetProperty(g.unite, kAudioUnitProperty_StreamFormat,
                              kAudioUnitScope_Input, 0, &fmt, sizeof fmt);
    if (st != noErr) {
      erreur("format float32 stéréo refusé par l'unité de sortie (%d)",
             (int)st);
      return TRAMES_AUDIO_STATUT_FORMAT;
    }
    g.non_entrelace = 1;
    journal("format entrelacé refusé : repli sur deux tampons non "
            "entrelacés");
  }

  AURenderCallbackStruct rappel;
  rappel.inputProc = rendre;
  rappel.inputProcRefCon = NULL;
  st = AudioUnitSetProperty(g.unite, kAudioUnitProperty_SetRenderCallback,
                            kAudioUnitScope_Input, 0, &rappel, sizeof rappel);
  if (st != noErr) {
    erreur("rappel de rendu refusé (%d)", (int)st);
    return TRAMES_AUDIO_STATUT_INTERNE;
  }

  st = AudioUnitInitialize(g.unite);
  if (st != noErr) {
    erreur("initialisation de l'unité de sortie impossible (%d)", (int)st);
    return TRAMES_AUDIO_STATUT_INTERNE;
  }
  g.initialisee = 1;

  st = AudioOutputUnitStart(g.unite);
  if (st != noErr) {
    erreur("démarrage de la sortie audio impossible (%d)", (int)st);
    arreter_unite();
    return TRAMES_AUDIO_STATUT_INTERNE;
  }
  g.demarre = 1;
  return TRAMES_AUDIO_STATUT_OK;
}

/* ------------------------------------------------------------------ */
/* Socket : écriture et lecture bornées                                */

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

static int envoyer_trame(uint8_t type, const uint8_t *corps, uint16_t longueur)
{
  uint8_t trame[TRAMES_ENTETE_TAILLE + TRAMES_AUDIO_DEVICE_TAILLE_MIN +
                 TRAMES_AUDIO_NOM_MAX];
  if (longueur > TRAMES_AUDIO_DEVICE_TAILLE_MIN + TRAMES_AUDIO_NOM_MAX)
    return -1;
  const int n = trame_encoder(trame, sizeof trame, type, 0, corps, longueur);
  if (n < 0)
    return -1;
  return ecrire_tout(g.client_fd, trame, (size_t)n);
}

/* Lit exactement n octets, en abandonnant proprement sur signal ou délai.
   Renvoie 0, -1 sur fin/erreur ou expiration du délai. */
static int lire_exact(int fd, uint8_t *sortie, size_t n, int delai_ms)
{
  const long long echeance = maintenant_ns() + (long long)delai_ms * 1000000LL;
  size_t fait = 0;
  while (fait < n) {
    if (arret_demande)
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

/* ------------------------------------------------------------------ */
/* Fichier anneau partagé : c'est nous qui le créons, le possédons      */

static int preparer_anneau(void)
{
  const size_t total =
      sizeof(struct anneau_entete) + (size_t)ANNEAU_AUDIO_CAPACITE_MAX *
                                         OCTETS_TRAME;
  /* O_TRUNC récupère un fichier laissé par un assistant tué par SIGKILL. */
  const int fd = open(g.chemin_pcm, O_RDWR | O_CREAT | O_TRUNC, 0600);
  if (fd < 0) {
    erreur("ouverture de %s : %s", g.chemin_pcm, strerror(errno));
    return -1;
  }
  if (fchmod(fd, 0600) < 0)
    erreur("fchmod %s : %s", g.chemin_pcm, strerror(errno));
  if (ftruncate(fd, (off_t)total) < 0) {
    erreur("ftruncate de %s : %s", g.chemin_pcm, strerror(errno));
    close(fd);
    return -1;
  }
  void *p = mmap(NULL, total, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  const int e = errno;
  close(fd);
  if (p == MAP_FAILED) {
    errno = e;
    erreur("mmap de %s : %s", g.chemin_pcm, strerror(errno));
    return -1;
  }
  g.anneau = (struct anneau_entete *)p;
  g.taille_anneau = total;
  if (anneau_initialiser(g.anneau, CANAUX, (uint32_t)OCTETS_TRAME, 48000, 512,
                         ANNEAU_AUDIO_CAPACITE_MAX, 1) != 0) {
    erreur("en-tête d'anneau non initialisable");
    munmap(g.anneau, g.taille_anneau);
    g.anneau = NULL;
    g.taille_anneau = 0;
    return -1;
  }
  g.capacite = ANNEAU_AUDIO_CAPACITE_MAX;
  g.pcm_proprietaire = 1;
  journal("anneau créé : %s (%zu octets, capacité %u trames)", g.chemin_pcm,
          total, (unsigned)ANNEAU_AUDIO_CAPACITE_MAX);
  return 0;
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
/* Session avec un client organum                                      */

static void fermer_client(int adieu)
{
  if (g.etat == ETAT_AUCUN)
    return;
  if (adieu && g.etat == ETAT_CONNECTE && g.client_fd >= 0)
    envoyer_trame(TRAMES_AUDIO_TYPE_BYE, NULL, 0);
  if (g.client_fd >= 0) {
    close(g.client_fd);
    g.client_fd = -1;
  }
  g.etat = ETAT_AUCUN;
  g.debut = 0;
  g.fin = 0;
  /* Plus personne ne produit : arrêter la lecture évite de brasser du
     silence. Le prochain AUDIO_CONFIG redémarrera l'unité. */
  if (g.anneau != NULL)
    atomic_store_explicit(&g.anneau->arret, 1, memory_order_release);
  arreter_unite();
  journal("client déconnecté");
}

static uint8_t appliquer_config(const struct audio_config_vue *cfg)
{
  if (g.anneau == NULL)
    return TRAMES_AUDIO_STATUT_INTERNE;
  /* L'assistant possède l'en-tête, mais un fichier ou un mappage incohérent
     ne doit jamais être utilisé en silence : un désaccord de version est un
     refus explicite (statut 3), pas une session qui ne produit rien. */
  if (g.anneau->magie != ANNEAU_AUDIO_MAGIE ||
      g.anneau->version != ANNEAU_AUDIO_VERSION) {
    erreur("en-tête d'anneau incompatible (magie 0x%08x, version %u, "
           "attendue %u)",
           (unsigned)g.anneau->magie, (unsigned)g.anneau->version,
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
  if (g.anneau == NULL)
    return TRAMES_AUDIO_STATUT_INTERNE;

  struct sortie s;
  if (!interroger_sortie(&s)) {
    /* Machine sans carte son (VM de test) : refus explicite, statut 2. */
    if (g.demarre) {
      arreter_unite();
      atomic_store_explicit(&g.anneau->arret, 1, memory_order_release);
    }
    return TRAMES_AUDIO_STATUT_AUCUNE_SORTIE;
  }

  /* Changement de taux à chaud, ou reprise après une perte : on arrête,
     on réécrit l'en-tête, on reformate, on initialise et on relance. */
  arreter_unite();
  if (anneau_initialiser(g.anneau, CANAUX, (uint32_t)OCTETS_TRAME, cfg->taux,
                         cfg->periode, cfg->capacite, cfg->generation) != 0)
    return TRAMES_AUDIO_STATUT_CONFIG;
  g.capacite = cfg->capacite;
  g.taux = cfg->taux;
  g.periode = cfg->periode;

  const uint8_t statut = preparer_unite(cfg->taux);
  if (statut != TRAMES_AUDIO_STATUT_OK) {
    atomic_store_explicit(&g.anneau->arret, 1, memory_order_release);
    arreter_unite();
    return statut;
  }
  journal("sortie configurée : %s, %u Hz, %u canal(aux), %s", s.nom,
          (unsigned)cfg->taux, (unsigned)cfg->canaux,
          g.non_entrelace ? "non entrelacé" : "entrelacé");
  return TRAMES_AUDIO_STATUT_OK;
}

static void repondre_config(const uint8_t *corps, uint16_t longueur)
{
  struct audio_config_vue cfg;
  if (audio_config_decoder(corps, longueur, &cfg) != 0) {
    erreur("AUDIO_CONFIG malformé : trame ignorée");
    return;
  }
  journal("CONFIG reçue : génération=%u taux=%u période=%u canaux=%u "
          "format=%u capacité=%u octets=%u",
          cfg.generation, cfg.taux, cfg.periode, cfg.canaux, cfg.format,
          cfg.capacite, cfg.octets);

  const uint8_t statut = appliquer_config(&cfg);

  struct audio_ack_vue ack;
  memset(&ack, 0, sizeof ack);
  ack.statut = statut;
  ack.generation = cfg.generation;
  ack.taux = cfg.taux;
  ack.periode = cfg.periode;
  ack.capacite = g.capacite;
  uint8_t corps_ack[TRAMES_AUDIO_ACK_TAILLE];
  const int n = audio_ack_encoder(corps_ack, sizeof corps_ack, &ack);
  if (n < 0 || envoyer_trame(TRAMES_AUDIO_TYPE_ACK, corps_ack, (uint16_t)n) <
                   0) {
    erreur("acquittement audio impossible à envoyer");
    fermer_client(0);
    return;
  }
  journal("ACK envoyé : statut=%u taux=%u période=%u capacité=%u", statut,
          cfg.taux, cfg.periode, g.capacite);
  if (statut != TRAMES_AUDIO_STATUT_OK)
    return;

  struct sortie s;
  struct audio_device_vue dev;
  memset(&dev, 0, sizeof dev);
  memset(&s, 0, sizeof s);
  if (interroger_sortie(&s)) {
    dev.nom_len = (uint8_t)strlen(s.nom);
    if (dev.nom_len > TRAMES_AUDIO_NOM_MAX)
      dev.nom_len = TRAMES_AUDIO_NOM_MAX;
    dev.nom = (const uint8_t *)s.nom;
    dev.taux_natif = s.taux;
    dev.latence_us = s.latence_us;
  }
  uint8_t corps_dev[TRAMES_AUDIO_DEVICE_TAILLE_MIN + TRAMES_AUDIO_NOM_MAX];
  const int nd = audio_device_encoder(corps_dev, sizeof corps_dev, &dev);
  if (nd > 0 && envoyer_trame(TRAMES_AUDIO_TYPE_DEVICE, corps_dev,
                              (uint16_t)nd) < 0)
    journal("AUDIO_DEVICE perdu (écriture impossible)");
}

/* Traite toutes les trames complètes déjà présentes. Renvoie 0, ou -1 si la
   session s'arrête. */
static int traiter_entree(void)
{
  for (;;) {
    struct trame_vue vue;
    size_t consommes = 0;
    const int code =
        trame_decoder(&g.decodeur, g.entree + g.debut,
                      (size_t)(g.fin - g.debut), &vue, &consommes);
    if (code < 0) {
      erreur("longueur de trame supérieure à max_frame : fermeture");
      fermer_client(0);
      return -1;
    }
    if (code == 0) {
      g.debut = g.fin = 0;
      return 0;
    }
    g.debut += (int)consommes;

    switch (vue.type) {
    case TRAMES_AUDIO_TYPE_CONFIG:
      repondre_config(vue.corps, vue.longueur);
      if (g.etat == ETAT_AUCUN)
        return -1;
      break;
    case TRAMES_AUDIO_TYPE_PING:
      if (envoyer_trame(TRAMES_AUDIO_TYPE_PONG, NULL, 0) < 0) {
        fermer_client(0);
        return -1;
      }
      break;
    case TRAMES_AUDIO_TYPE_STOP:
      journal("AUDIO_STOP reçu d'organum");
      break;
    case TRAMES_AUDIO_TYPE_BYE:
      journal("BYE reçu d'organum");
      fermer_client(0);
      return -1;
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
    fermer_client(0);
    return -1;
  }
  const ssize_t r =
      recv(g.client_fd, g.entree + g.fin, sizeof g.entree - (size_t)g.fin, 0);
  if (r == 0) {
    journal("fin de flux");
    fermer_client(0);
    return -1;
  }
  if (r < 0) {
    if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)
      return 0;
    erreur("lecture de la socket : %s", strerror(errno));
    fermer_client(0);
    return -1;
  }
  g.fin += (int)r;
  return traiter_entree();
}

/* Accepte un client et échange la poignée dans le délai le plus court
   possible : organum n'attend que 200 ms pour la réponse. */
static void accepter_client(void)
{
  const int fd = accept(g.ecoute, NULL, NULL);
  if (fd < 0) {
    if (errno != EINTR)
      erreur("accept : %s", strerror(errno));
    return;
  }

  if (g.etat != ETAT_AUCUN) {
    /* Une reconnexion d'organum arrive souvent dans le même tour de poll que
       la fin de flux de la connexion précédente : laisser une courte chance
       à cet EOF évite de refuser une reprise légitime. */
    struct pollfd p = {g.client_fd, POLLIN, 0};
    if (poll(&p, 1, 20) > 0 &&
        (p.revents & (POLLIN | POLLHUP | POLLERR)))
      lire_client();
  }

  if (g.etat != ETAT_AUCUN) {
    /* Un seul client. Le protocole audio n'a pas de statut « déjà un
       client » : on lit la poignée pour éviter un RST, on répond un statut
       interne puis on ferme. */
    uint8_t poignee[TRAMES_AUDIO_POIGNEE_TAILLE];
    uint8_t reponse[TRAMES_AUDIO_POIGNEE_TAILLE];
    lire_exact(fd, poignee, sizeof poignee, DELAI_POIGNEE);
    poignee_audio_encoder(reponse, TRAMES_AUDIO_STATUT_INTERNE, MAX_FRAME);
    ecrire_tout(fd, reponse, sizeof reponse);
    close(fd);
    journal("deuxième client refusé (déjà un abonné)");
    return;
  }

  uint8_t poignee[TRAMES_AUDIO_POIGNEE_TAILLE];
  if (lire_exact(fd, poignee, sizeof poignee, DELAI_POIGNEE) != 0) {
    erreur("poignée de main non reçue dans le délai");
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
  poignee_audio_encoder(reponse, statut, MAX_FRAME);
  if (ecrire_tout(fd, reponse, sizeof reponse) < 0) {
    erreur("réponse de poignée de main impossible");
    close(fd);
    return;
  }
  if (statut != TRAMES_AUDIO_STATUT_OK) {
    journal("poignée refusée (code %d, statut %u, client version %u, "
            "attendue %u)",
            code, (unsigned)statut, (unsigned)vue.version,
            (unsigned)TRAMES_AUDIO_VERSION);
    close(fd);
    return;
  }

  g.max_frame = vue.max_frame;
  if (g.max_frame > MAX_FRAME)
    g.max_frame = MAX_FRAME;
  trame_decodeur_init(&g.decodeur, g.max_frame);
  g.client_fd = fd;
  g.debut = 0;
  g.fin = 0;
  g.etat = ETAT_CONNECTE;
  journal("poignée acceptée (max_frame %u)", g.max_frame);
}

/* ------------------------------------------------------------------ */
/* Surveillance du périphérique par défaut                             */

static OSStatus sur_peripherique(AudioObjectID objet, UInt32 n,
                                 const AudioObjectPropertyAddress *adresses,
                                 void *contexte)
{
  (void)objet;
  (void)n;
  (void)adresses;
  (void)contexte;
  atomic_store_explicit(&g.peripherique_change, 1, memory_order_release);
  return noErr;
}

/* Perte du périphérique en cours de jeu : arrêt de la lecture et AUDIO_STOP,
   sans quitter. Organum verra arret dans l'en-tête, fermera, puis réessaiera
   comme après un démarrage sans assistant. */
static void verifier_peripherique(void)
{
  const time_t maintenant = time(NULL);
  const int signale =
      atomic_exchange_explicit(&g.peripherique_change, 0, memory_order_acq_rel);
  if (!signale && maintenant == g.derniere_verif)
    return;
  g.derniere_verif = maintenant;

  if (!g.demarre)
    return;
  if (interroger_sortie(NULL))
    return;

  erreur("périphérique de sortie perdu : lecture arrêtée");
  atomic_store_explicit(&g.anneau->arret, 1, memory_order_release);
  struct audio_stop_vue stop;
  stop.raison = RAISON_PERIPHERIQUE_PERDU;
  uint8_t corps[TRAMES_AUDIO_STOP_TAILLE];
  const int n = audio_stop_encoder(corps, sizeof corps, &stop);
  if (n > 0 && g.client_fd >= 0 &&
      envoyer_trame(TRAMES_AUDIO_TYPE_STOP, corps, (uint16_t)n) < 0)
    journal("AUDIO_STOP perdu (écriture impossible)");
  arreter_unite();
}

/* ------------------------------------------------------------------ */
/* Diagnostic --liste                                                  */

static int lister_sortie(void)
{
  struct sortie s;
  if (!interroger_sortie(&s)) {
    printf("organum-audio : aucune sortie audio disponible : aucun "
           "périphérique de sortie par défaut.\n");
    printf("organum-audio : une machine virtuelle sans carte son n'en a "
           "aucun ; organum restera alors en audio dégradé, sans planter.\n");
    printf("organum-audio : sur un Mac réel, vérifiez « Réglages Système → "
           "Son → Sortie » ou branchez un périphérique USB.\n");
    return 1;
  }
  printf("organum-audio : sortie par défaut : « %s »\n", s.nom);
  printf("organum-audio :   taux nominal %u Hz, %u canal(aux) de sortie, "
         "latence estimée %u µs\n",
         (unsigned)s.taux, (unsigned)s.canaux, (unsigned)s.latence_us);
  printf("organum-audio :   l'anneau sera <chemin socket>.pcm, %u trames "
         "float32 entrelacées\n",
         (unsigned)ANNEAU_AUDIO_CAPACITE_MAX);
  return 0;
}

/* ------------------------------------------------------------------ */
/* Arrêt                                                               */

static void arreter_assistant(void)
{
  arret_demande = 1;
  detruire_unite();
  fermer_client(0);
  if (g.anneau != NULL) {
    munmap(g.anneau, g.taille_anneau);
    g.anneau = NULL;
    g.taille_anneau = 0;
  }
  if (g.pcm_proprietaire) {
    if (unlink(g.chemin_pcm) < 0 && errno != ENOENT)
      erreur("unlink %s : %s", g.chemin_pcm, strerror(errno));
    g.pcm_proprietaire = 0;
  }
  if (g.ecoute >= 0) {
    close(g.ecoute);
    g.ecoute = -1;
  }
  if (g.proprietaire) {
    if (unlink(g.chemin) < 0 && errno != ENOENT)
      erreur("unlink %s : %s", g.chemin, strerror(errno));
    g.proprietaire = 0;
  }
}

static void sur_signal(int sig)
{
  (void)sig;
  arret_demande = 1;
}

static void aide(const char *programme)
{
  printf("Usage : %s [--socket CHEMIN] [--verbose] [--liste]\n\n"
         "  --socket CHEMIN  force le chemin de la socket\n"
         "  --verbose        journal détaillé sur la sortie d'erreur\n"
         "  --liste          affiche la sortie audio par défaut et sort\n"
         "                   (code 0 si une sortie existe, 1 sinon)\n\n"
         "La sortie est toujours le périphérique système par défaut.\n",
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

  char chemin[TRAMES_SUN_PATH_MAX];
  if (socket_arg != NULL) {
    const size_t taille = strlen(socket_arg);
    if (taille == 0 || taille >= sizeof chemin) {
      erreur("chemin --socket invalide");
      return 2;
    }
    memcpy(chemin, socket_arg, taille + 1);
  } else if (trame_chemin_socket_nom(getenv("ORGANUM_AUDIO_SOCKET"),
                                     getenv("TMPDIR"),
                                     (unsigned long)getuid(), "organum-audio-",
                                     chemin, sizeof chemin) != 0) {
    erreur("chemin de socket par défaut invalide (trop long)");
    return 2;
  }

  if (liste)
    return lister_sortie();

  const size_t n = strlen(chemin);
  if (n + sizeof ".pcm" > sizeof g.chemin_pcm) {
    erreur("chemin de socket trop long pour le fichier anneau");
    return 2;
  }
  memcpy(g.chemin, chemin, n + 1);
  memcpy(g.chemin_pcm, chemin, n);
  memcpy(g.chemin_pcm + n, ".pcm", sizeof ".pcm");

  signal(SIGINT, sur_signal);
  signal(SIGTERM, sur_signal);
  signal(SIGPIPE, SIG_IGN);

  g.ecoute = -1;
  g.client_fd = -1;
  g.etat = ETAT_AUCUN;
  g.max_frame = MAX_FRAME;
  atomic_init(&g.peripherique_change, 0);

  if (preparer_anneau() != 0)
    return 1;

  const int ecoute = ouvrir_ecoute(chemin);
  if (ecoute < 0) {
    arreter_assistant();
    return ecoute == -3 ? 3 : 1;
  }
  g.ecoute = ecoute;
  g.proprietaire = 1;
  journal("écoute sur %s", chemin);

  /* Un changement de périphérique par défaut se voit par ce rappel ; la
     boucle revérifie aussi une fois par seconde. */
  AudioObjectPropertyAddress adresse = {
      kAudioHardwarePropertyDefaultOutputDevice,
      kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
  if (AudioObjectAddPropertyListener(kAudioObjectSystemObject, &adresse,
                                     sur_peripherique, NULL) != noErr)
    journal("surveillance du périphérique par défaut indisponible");

  struct sortie s;
  if (!interroger_sortie(&s))
    erreur("aucune sortie audio disponible pour l'instant : les demandes "
           "d'organum seront refusées (statut 2) jusqu'à son apparition");
  else
    journal("sortie par défaut : %s (%u Hz, %u canal(aux))", s.nom,
            (unsigned)s.taux, (unsigned)s.canaux);

  while (!arret_demande) {
    verifier_peripherique();

    struct pollfd p[2];
    p[0].fd = g.ecoute;
    p[0].events = POLLIN;
    p[0].revents = 0;
    nfds_t nfds = 1;
    if (g.etat != ETAT_AUCUN && g.client_fd >= 0) {
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

  journal("arrêt demandé");
  AudioObjectRemovePropertyListener(kAudioObjectSystemObject, &adresse,
                                    sur_peripherique, NULL);
  arreter_assistant();
  return 0;
}
