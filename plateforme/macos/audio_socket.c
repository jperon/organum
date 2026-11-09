/* Sortie audio macOS par socket Unix et anneau partagé, dialogue avec un
 * assistant CoreAudio externe.
 *
 * CoreAudio n'est accessible que depuis un binaire Mach-O, hors de l'APE
 * cosmopolitan : un assistant externe ouvre la socket et un fichier anneau
 * (mmap MAP_SHARED), joue les échantillons float32 entrelacés que nous y
 * déposons et publie ses compteurs d'incidents. Ce backend est le client de
 * cette socket. Le codec est dans trames_audio.h, l'anneau dans
 * anneau_audio.h.
 *
 * Le périphérique demandé est ignoré en v1 : l'assistant utilise la sortie
 * système par défaut. Le chemin de la socket est résolu une seule fois à
 * l'ouverture ; audio_ecrire(), appelée dans le fil audio, ne fait ni getenv
 * ni allocation.
 *
 * Comme pour le MIDI, la structure de contrôle est en mémoire partagée : les
 * fils de requête redbean héritent du descripteur et du mappage, mais seul le
 * processus créateur écrit dans l'anneau. Un fils doit oublier l'anneau hérité
 * (audio_socket_audio_oublier_fils) pour ne pas retenir le fichier ouvert. */
#include <cosmo.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
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

#include "../backends.h"
#include "anneau_audio.h"
#include "trames_audio.h"

#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0
#endif
#ifndef MSG_DONTWAIT
#define MSG_DONTWAIT 0
#endif

/* Toute l'ouverture est bornée : un assistant figé ne doit pas retarder le
   démarrage de l'orgue de plus de quelques dixièmes de seconde. */
#define AUDIO_SOCKET_DELAI_NS 200000000LL
#define AUDIO_SOCKET_MAX_FRAME TRAMES_MAX_FRAME_MAX
#define AUDIO_SOCKET_TAMPON 512

struct audio {
    int fd;
    /* Structure en mémoire partagée : les fils de requête doivent lire
       connecte/perdu/trames_jouees sans toucher au mappage de l'anneau. */
    int partage;
    pid_t createur;
    int chemin_valide;
    char chemin[TRAMES_SUN_PATH_MAX];
    char chemin_pcm[TRAMES_SUN_PATH_MAX + 8];

    struct anneau_entete *anneau;
    size_t taille_anneau;
    uint32_t capacite;
    uint32_t generation;
    uint16_t max_frame;

    int taux;
    int periode;
    int canaux;

    /* Publiés par le processus créateur, lus par l'API dans les fils. */
    atomic_int perdu;
    atomic_int connecte;
    atomic_uint_fast64_t trames_jouees;
};

/* Instance courante du processus. Elle est héritée par fork ; un fils s'en
   sert uniquement pour oublier le mappage et fermer sa copie du
   descripteur. */
static struct audio *g_instance;
static int g_fils_a_oublie;

static char g_erreur[256];

static void definir_erreur(const char *message)
{
    if (message == NULL || message[0] == '\0')
        message = "erreur audio inconnue";
    snprintf(g_erreur, sizeof g_erreur, "%s", message);
}

static const char *message_statut(uint8_t statut)
{
    switch (statut) {
    case TRAMES_AUDIO_STATUT_FORMAT:
        return "format audio refusé par l'assistant";
    case TRAMES_AUDIO_STATUT_AUCUNE_SORTIE:
        return "aucune sortie audio disponible";
    case TRAMES_AUDIO_STATUT_CONFIG:
        return "configuration audio refusée par l'assistant";
    case TRAMES_AUDIO_STATUT_INTERNE:
        return "erreur interne de l'assistant audio";
    default:
        return "assistant audio : statut inconnu";
    }
}

/* Horloge murale : sous XNU x86-64, CLOCK_MONOTONIC de cosmocc est reconstitué
   depuis le TSC avec un diviseur supposant 3 GHz (libc/intrin/
   clock_gettime-mono.c:80), donc il avance à ~0,29 × le temps réel sur une VM
   lente. Les échéances « humaines » passent par CLOCK_REALTIME sous XNU et
   gardent CLOCK_MONOTONIC sous Linux, insensible aux sauts NTP. */
static void horloge_mur(struct timespec *t)
{
    clock_gettime(IsXnu() ? CLOCK_REALTIME : CLOCK_MONOTONIC, t);
}

static int64_t instant_ns(void)
{
    struct timespec t;
    horloge_mur(&t);
    return (int64_t)t.tv_sec * 1000000000LL + (int64_t)t.tv_nsec;
}

/* Attend un événement jusqu'à l'échéance. 1 prêt, 0 délai dépassé, -1 erreur. */
static int attendre_fd(int fd, short events, int64_t echeance)
{
    for (;;) {
        const int64_t reste = echeance - instant_ns();
        if (reste <= 0)
            return 0;
        int64_t ms = reste / 1000000LL;
        if (ms <= 0)
            ms = 1;
        if (ms > 200)
            ms = 200;
        struct pollfd p = {fd, events, 0};
        const int r = poll(&p, 1, (int)ms);
        if (r > 0)
            return 1;
        if (r == 0)
            continue;
        if (errno == EINTR)
            continue;
        return -1;
    }
}

static int ecrire_tout_delai(int fd, const uint8_t *octets, size_t n,
                             int64_t echeance)
{
    size_t fait = 0;
    while (fait < n) {
        const ssize_t w = send(fd, octets + fait, n - fait, MSG_NOSIGNAL);
        if (w > 0) {
            fait += (size_t)w;
            continue;
        }
        if (w < 0 && errno == EINTR)
            continue;
        if (w < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            const int pret = attendre_fd(fd, POLLOUT, echeance);
            if (pret == 1)
                continue;
            if (pret == 0)
                errno = ETIMEDOUT;
            return -1;
        }
        if (w == 0)
            errno = EPIPE;
        return -1;
    }
    return 0;
}

static int lire_tout_delai(int fd, uint8_t *octets, size_t n, int64_t echeance)
{
    size_t fait = 0;
    while (fait < n) {
        const ssize_t r = recv(fd, octets + fait, n - fait, 0);
        if (r > 0) {
            fait += (size_t)r;
            continue;
        }
        if (r == 0) {
            errno = EPIPE;
            return -1;
        }
        if (errno == EINTR)
            continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            const int pret = attendre_fd(fd, POLLIN, echeance);
            if (pret == 1)
                continue;
            if (pret == 0)
                errno = ETIMEDOUT;
            return -1;
        }
        return -1;
    }
    return 0;
}

static int envoyer_trame(int fd, uint8_t type, const uint8_t *corps,
                         uint16_t longueur, int64_t echeance)
{
    uint8_t trame[TRAMES_ENTETE_TAILLE + TRAMES_AUDIO_CONFIG_TAILLE];
    const int n =
        trame_encoder(trame, sizeof trame, type, 0, corps, longueur);
    if (n < 0) {
        errno = EINVAL;
        return -1;
    }
    return ecrire_tout_delai(fd, trame, (size_t)n, echeance);
}

/* Construit le chemin du fichier anneau et vérifie qu'il tient dans le
   tampon. */
static int construire_chemin_pcm(struct audio *a)
{
    const size_t n = strlen(a->chemin);
    if (n + sizeof ".pcm" > sizeof a->chemin_pcm) {
        errno = ENAMETOOLONG;
        return -1;
    }
    memcpy(a->chemin_pcm, a->chemin, n);
    memcpy(a->chemin_pcm + n, ".pcm", sizeof ".pcm");
    return 0;
}

/* Valide l'en-tête de l'anneau créé par l'assistant. La capacité et les
   descripteurs de trame sont figés par l'assistant : on ne les invente pas,
   on vérifie qu'ils correspondent exactement au format que nous produisons
   (float32 entrelacé stéréo). */
static int valider_anneau(struct audio *a, const struct stat *st)
{
    struct anneau_entete *e = a->anneau;
    if (e->magie != ANNEAU_AUDIO_MAGIE) {
        definir_erreur("anneau audio : magie invalide");
        errno = EPROTO;
        return -1;
    }
    if (e->version != ANNEAU_AUDIO_VERSION) {
        definir_erreur("anneau audio : version incompatible");
        errno = EPROTO;
        return -1;
    }
    if (e->canaux != (uint32_t)a->canaux) {
        definir_erreur("anneau audio : nombre de canaux incompatible");
        errno = EPROTO;
        return -1;
    }
    if (e->octets_trame != (uint32_t)a->canaux * sizeof(float)) {
        definir_erreur("anneau audio : taille de trame incompatible");
        errno = EPROTO;
        return -1;
    }
    if (e->capacite < ANNEAU_AUDIO_CAPACITE_MIN ||
        e->capacite > ANNEAU_AUDIO_CAPACITE_MAX ||
        (e->capacite & (e->capacite - 1u)) != 0) {
        definir_erreur("anneau audio : capacité invalide");
        errno = EPROTO;
        return -1;
    }
    const uint64_t necessaire = (uint64_t)sizeof(struct anneau_entete) +
                                (uint64_t)e->capacite * e->octets_trame;
    if (st->st_size < 0 || (uint64_t)st->st_size < necessaire) {
        definir_erreur("anneau audio : fichier trop court");
        errno = EPROTO;
        return -1;
    }
    a->capacite = e->capacite;
    return 0;
}

static int attendre_ack(struct audio *a, int64_t echeance)
{
    struct trame_decodeur decodeur;
    trame_decodeur_init(&decodeur, a->max_frame);
    uint8_t tampon[AUDIO_SOCKET_TAMPON];

    for (;;) {
        const ssize_t r = recv(a->fd, tampon, sizeof tampon, MSG_DONTWAIT);
        if (r > 0) {
            size_t pos = 0;
            while (pos < (size_t)r) {
                struct trame_vue vue;
                size_t consommes = 0;
                const int code =
                    trame_decoder(&decodeur, tampon + pos, (size_t)r - pos,
                                  &vue, &consommes);
                if (code == -1) {
                    definir_erreur("trame audio malformée");
                    errno = EPROTO;
                    return -1;
                }
                if (code == 0) {
                    pos = (size_t)r;
                    break;
                }
                pos += consommes;
                switch (vue.type) {
                case TRAMES_AUDIO_TYPE_ACK: {
                    struct audio_ack_vue ack;
                    if (audio_ack_decoder(vue.corps, vue.longueur, &ack) != 0) {
                        definir_erreur("acquittement audio malformé");
                        errno = EPROTO;
                        return -1;
                    }
                    if (ack.statut != TRAMES_AUDIO_STATUT_OK) {
                        definir_erreur(message_statut(ack.statut));
                        errno = EIO;
                        return -1;
                    }
                    a->generation = ack.generation;
                    return 0;
                }
                case TRAMES_AUDIO_TYPE_STOP:
                    definir_erreur("sortie audio arrêtée par l'assistant");
                    errno = ENODEV;
                    return -1;
                case TRAMES_AUDIO_TYPE_BYE:
                    definir_erreur("assistant audio déconnecté");
                    errno = ENODEV;
                    return -1;
                case TRAMES_AUDIO_TYPE_PING:
                    /* Réponse au mieux : un PONG perdu ne coupe pas la
                       session. */
                    envoyer_trame(a->fd, TRAMES_AUDIO_TYPE_PONG, NULL, 0,
                                  echeance);
                    break;
                default:
                    break; /* type inconnu : ignoré */
                }
            }
            continue;
        }
        if (r == 0) {
            definir_erreur("assistant audio déconnecté");
            errno = ENODEV;
            return -1;
        }
        if (errno == EINTR)
            continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            const int pret = attendre_fd(a->fd, POLLIN, echeance);
            if (pret == 1)
                continue;
            if (pret == 0) {
                definir_erreur("délai d'acquittement audio dépassé");
                errno = ETIMEDOUT;
            } else {
                definir_erreur("assistant audio injoignable");
            }
            return -1;
        }
        definir_erreur("lecture de la socket audio impossible");
        return -1;
    }
}

static void liberer_echec(struct audio *a)
{
    if (a == NULL)
        return;
    if (a->anneau != NULL && a->taille_anneau != 0)
        munmap(a->anneau, a->taille_anneau);
    if (a->fd >= 0)
        close(a->fd);
    if (a->partage)
        munmap(a, sizeof *a);
    else
        free(a);
}

audio_t *audio_socket_audio_ouvrir(const char *peripherique, int taux,
                                   int canaux, int periode, int nb_periodes)
{
    (void)peripherique;  /* v1 : sortie système par défaut de l'assistant. */
    (void)nb_periodes;   /* la profondeur est celle de l'anneau de l'assistant. */

    g_erreur[0] = '\0';
    if (taux <= 0 || canaux <= 0 || periode <= 0) {
        definir_erreur("paramètres audio invalides");
        errno = EINVAL;
        return NULL;
    }
    if (canaux != 2) {
        definir_erreur("seul le stéréo entrelacé est pris en charge");
        errno = EINVAL;
        return NULL;
    }

    struct audio *a = mmap(NULL, sizeof *a, PROT_READ | PROT_WRITE,
                           MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    int partage = 1;
    if (a == MAP_FAILED) {
        a = (struct audio *)calloc(1, sizeof *a);
        partage = 0;
    }
    if (a == NULL) {
        definir_erreur("mémoire insuffisante pour le backend audio");
        return NULL;
    }
    memset(a, 0, sizeof *a);
    a->fd = -1;
    a->partage = partage;
    a->createur = getpid();
    a->taux = taux;
    a->periode = periode;
    a->canaux = canaux;
    a->max_frame = AUDIO_SOCKET_MAX_FRAME;
    atomic_init(&a->perdu, 0);
    atomic_init(&a->connecte, 0);
    atomic_init(&a->trames_jouees, 0);

    const int64_t echeance = instant_ns() + AUDIO_SOCKET_DELAI_NS;

    /* Le chemin est figé ici : ni audio_ecrire() ni les fils ne font de
       getenv. ORGANUM_AUDIO_SOCKET reste un forçage de test sous Linux. */
    const char *env = getenv("ORGANUM_AUDIO_SOCKET");
    const char *tmpdir = getenv("TMPDIR");
    if (trame_chemin_socket_nom(env, tmpdir, (unsigned long)getuid(),
                                "organum-audio-", a->chemin,
                                sizeof a->chemin) != 0) {
        definir_erreur("chemin de la socket audio trop long");
        errno = ENAMETOOLONG;
        liberer_echec(a);
        return NULL;
    }
    a->chemin_valide = 1;
    if (construire_chemin_pcm(a) != 0) {
        definir_erreur("chemin de l'anneau audio trop long");
        liberer_echec(a);
        return NULL;
    }

    a->fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (a->fd < 0) {
        char message[160];
        snprintf(message, sizeof message, "socket audio impossible : %s",
                 strerror(errno));
        definir_erreur(message);
        liberer_echec(a);
        return NULL;
    }
    const int drapeaux = fcntl(a->fd, F_GETFL, 0);
    if (drapeaux < 0 ||
        fcntl(a->fd, F_SETFL, drapeaux | O_NONBLOCK) < 0) {
        definir_erreur("socket audio non bloquante impossible");
        liberer_echec(a);
        return NULL;
    }
#ifdef SO_NOSIGPIPE
    {
        int un = 1;
        setsockopt(a->fd, SOL_SOCKET, SO_NOSIGPIPE, &un, sizeof un);
    }
#endif

    struct sockaddr_un adresse;
    memset(&adresse, 0, sizeof adresse);
    adresse.sun_family = AF_UNIX;
    const size_t chemin_len = strlen(a->chemin);
    if (chemin_len >= sizeof adresse.sun_path) {
        definir_erreur("chemin de la socket audio trop long");
        errno = ENAMETOOLONG;
        liberer_echec(a);
        return NULL;
    }
    memcpy(adresse.sun_path, a->chemin, chemin_len + 1);

    if (connect(a->fd, (struct sockaddr *)&adresse, sizeof adresse) < 0) {
        int err = errno;
        if (err == EINPROGRESS || err == EALREADY || err == EWOULDBLOCK) {
            const int pret = attendre_fd(a->fd, POLLOUT, echeance);
            if (pret != 1) {
                if (pret == 0)
                    err = ETIMEDOUT;
                else
                    err = errno;
            } else {
                int detail = 0;
                socklen_t taille = sizeof detail;
                if (getsockopt(a->fd, SOL_SOCKET, SO_ERROR, &detail, &taille) <
                    0)
                    detail = errno;
                if (detail != 0)
                    err = detail;
                else
                    err = 0;
            }
        }
        if (err != 0) {
            char message[224];
            snprintf(message, sizeof message,
                     "assistant audio absent (socket %s) : %s", a->chemin,
                     strerror(err));
            definir_erreur(message);
            errno = err;
            liberer_echec(a);
            return NULL;
        }
    }

    /* Poignée de main : nous annonçons notre version, l'assistant répond.
       Un statut non nul est un refus explicite, pas une panne silencieuse. */
    uint8_t poignee[TRAMES_AUDIO_POIGNEE_TAILLE];
    poignee_audio_encoder(poignee, TRAMES_AUDIO_STATUT_OK,
                          AUDIO_SOCKET_MAX_FRAME);
    if (ecrire_tout_delai(a->fd, poignee, sizeof poignee, echeance) != 0) {
        definir_erreur("échange de poignée de main audio impossible");
        liberer_echec(a);
        return NULL;
    }
    if (lire_tout_delai(a->fd, poignee, sizeof poignee, echeance) != 0) {
        definir_erreur("assistant audio absent pendant la poignée de main");
        liberer_echec(a);
        return NULL;
    }
    struct poignee_vue vue;
    const int code = poignee_audio_decoder(poignee, &vue);
    if (code != 1) {
        if (code == 0)
            definir_erreur(message_statut(vue.statut));
        else if (code == -2)
            definir_erreur("version du protocole audio incompatible");
        else if (code == -3)
            definir_erreur("taille de trame audio incompatible");
        else
            definir_erreur("poignée de main audio invalide");
        errno = EPROTO;
        liberer_echec(a);
        return NULL;
    }
    a->max_frame = vue.max_frame;
    if (a->max_frame > AUDIO_SOCKET_MAX_FRAME)
        a->max_frame = AUDIO_SOCKET_MAX_FRAME;

    int fd_anneau = open(a->chemin_pcm, O_RDWR);
    if (fd_anneau < 0) {
        char message[224];
        snprintf(message, sizeof message,
                 "anneau audio absent (%s) : %s", a->chemin_pcm,
                 strerror(errno));
        definir_erreur(message);
        liberer_echec(a);
        return NULL;
    }
    struct stat st;
    if (fstat(fd_anneau, &st) != 0) {
        definir_erreur("anneau audio illisible");
        close(fd_anneau);
        liberer_echec(a);
        return NULL;
    }
    if (st.st_size < (off_t)sizeof(struct anneau_entete)) {
        definir_erreur("anneau audio : fichier trop court");
        close(fd_anneau);
        liberer_echec(a);
        return NULL;
    }
    void *mappage = mmap(NULL, (size_t)st.st_size, PROT_READ | PROT_WRITE,
                         MAP_SHARED, fd_anneau, 0);
    close(fd_anneau);
    if (mappage == MAP_FAILED) {
        definir_erreur("mappage de l'anneau audio impossible");
        liberer_echec(a);
        return NULL;
    }
    a->anneau = (struct anneau_entete *)mappage;
    a->taille_anneau = (size_t)st.st_size;
    if (valider_anneau(a, &st) != 0) {
        liberer_echec(a);
        return NULL;
    }

    /* En-tête : taux et période demandés, capacité validée par l'assistant.
       Repartir de compteurs nuls évite d'hériter d'une session précédente. */
    a->anneau->taux = (uint32_t)taux;
    a->anneau->periode = (uint32_t)periode;
    a->generation = 1;
    a->anneau->generation = a->generation;
    anneau_reinitialiser(a->anneau);

    struct audio_config_vue cfg;
    cfg.generation = a->generation;
    cfg.taux = (uint32_t)taux;
    cfg.periode = (uint32_t)periode;
    cfg.canaux = (uint16_t)canaux;
    cfg.format = TRAMES_AUDIO_FORMAT_FLOAT32_ENTRELACE;
    cfg.capacite = a->capacite;
    cfg.octets = a->capacite * a->anneau->octets_trame;
    uint8_t corps[TRAMES_AUDIO_CONFIG_TAILLE];
    const int ncorps = audio_config_encoder(corps, sizeof corps, &cfg);
    if (ncorps < 0 ||
        envoyer_trame(a->fd, TRAMES_AUDIO_TYPE_CONFIG, corps,
                      (uint16_t)ncorps, echeance) != 0) {
        definir_erreur("envoi de la configuration audio impossible");
        liberer_echec(a);
        return NULL;
    }
    if (attendre_ack(a, echeance) != 0) {
        liberer_echec(a);
        return NULL;
    }

    atomic_store_explicit(&a->connecte, 1, memory_order_release);
    atomic_store_explicit(&a->perdu, 0, memory_order_release);
    g_instance = a;
    g_fils_a_oublie = 0;
    g_erreur[0] = '\0';
    return a;
}

/* Sonde la socket sans bloquer : un EOF ou une erreur signifie que
   l'assistant a disparu. Les octets inattendus sont ignorés (BYE excepté). */
static void sonder_socket(struct audio *a)
{
    uint8_t tampon[64];
    const ssize_t r = recv(a->fd, tampon, sizeof tampon, MSG_DONTWAIT);
    if (r == 0) {
        atomic_store_explicit(&a->perdu, 1, memory_order_release);
        atomic_store_explicit(&a->connecte, 0, memory_order_release);
        return;
    }
    if (r < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)
            return;
        atomic_store_explicit(&a->perdu, 1, memory_order_release);
        atomic_store_explicit(&a->connecte, 0, memory_order_release);
        return;
    }
    for (ssize_t i = 0; i < r; ++i)
        if (tampon[i] == TRAMES_AUDIO_TYPE_BYE) {
            atomic_store_explicit(&a->perdu, 1, memory_order_release);
            atomic_store_explicit(&a->connecte, 0, memory_order_release);
            return;
        }
}

int audio_socket_audio_ecrire(audio_t *a, const float *entrelace, int trames)
{
    if (a == NULL || entrelace == NULL || trames < 0) {
        errno = EINVAL;
        return -1;
    }
    /* Un fils de requête n'écrit jamais : l'anneau appartient au processus
       créateur (fil audio). Il rend la main comme si tout était écrit. */
    if (a->createur != getpid())
        return trames;
    if (atomic_load_explicit(&a->perdu, memory_order_acquire) != 0 ||
        a->anneau == NULL) {
        errno = ENODEV;
        return -1;
    }
    if (trames == 0)
        return 0;
    if (atomic_load_explicit(&a->anneau->arret, memory_order_acquire) != 0) {
        atomic_store_explicit(&a->perdu, 1, memory_order_release);
        atomic_store_explicit(&a->connecte, 0, memory_order_release);
        errno = ENODEV;
        return -1;
    }

    const uint64_t periode_ns =
        (uint64_t)a->periode * 1000000000ULL / (uint32_t)a->taux;
    /* Quelques périodes : au-delà, l'assistant ne consomme plus. */
    int64_t echeance = instant_ns() + (int64_t)(periode_ns * 4ULL);
    size_t attente_ns = (size_t)(periode_ns / 8ULL);
    if (attente_ns < 200000ULL)
        attente_ns = 200000ULL;
    if (attente_ns > 5000000ULL)
        attente_ns = 5000000ULL;

    for (;;) {
        if (anneau_place_libre(a->anneau) >= (uint64_t)trames)
            break;
        if (atomic_load_explicit(&a->perdu, memory_order_acquire) != 0) {
            errno = ENODEV;
            return -1;
        }
        if (instant_ns() >= echeance) {
            /* Trames refusées faute de consommateur : même compteur que
               l'anneau, pour que les xruns publiés restent cohérents. */
            atomic_fetch_add_explicit(&a->anneau->overruns, (uint64_t)trames,
                                      memory_order_relaxed);
            errno = ENOSPC;
            return -1;
        }
        sonder_socket(a);
        if (atomic_load_explicit(&a->perdu, memory_order_acquire) != 0) {
            errno = ENODEV;
            return -1;
        }
        struct timespec pause = {(time_t)(attente_ns / 1000000000ULL),
                                 (long)(attente_ns % 1000000000ULL)};
        nanosleep(&pause, NULL);
    }

    const size_t ecrites = anneau_ecrire(a->anneau, entrelace, (size_t)trames);
    if (ecrites != (size_t)trames) {
        /* arret a pu être posé entre la vérification et l'écriture. */
        if (atomic_load_explicit(&a->anneau->arret, memory_order_acquire) != 0) {
            atomic_store_explicit(&a->perdu, 1, memory_order_release);
            atomic_store_explicit(&a->connecte, 0, memory_order_release);
            errno = ENODEV;
        } else {
            errno = ENOSPC;
        }
        return -1;
    }
    atomic_store_explicit(
        &a->trames_jouees,
        (uint64_t)atomic_load_explicit(&a->anneau->trames_jouees,
                                       memory_order_relaxed),
        memory_order_relaxed);
    return trames;
}

int audio_socket_audio_xruns(audio_t *a)
{
    if (a == NULL || a->anneau == NULL)
        return 0;
    /* Aucun appel système : deux lectures atomiques dans l'en-tête partagé. */
    const uint64_t underruns =
        atomic_load_explicit(&a->anneau->underruns, memory_order_relaxed);
    const uint64_t overruns =
        atomic_load_explicit(&a->anneau->overruns, memory_order_relaxed);
    const uint64_t total = underruns + overruns;
    return total > (uint64_t)INT_MAX ? INT_MAX : (int)total;
}

uint64_t audio_socket_audio_trames_jouees(audio_t *a)
{
    if (a == NULL)
        return 0;
    return (uint64_t)atomic_load_explicit(&a->trames_jouees,
                                          memory_order_relaxed);
}

int audio_socket_audio_perdue(audio_t *a)
{
    if (a == NULL)
        return 0;
    return atomic_load_explicit(&a->perdu, memory_order_acquire) != 0;
}

int audio_socket_audio_connecte(audio_t *a)
{
    if (a == NULL)
        return 0;
    return atomic_load_explicit(&a->connecte, memory_order_acquire) != 0 ? 1
                                                                         : 0;
}

int audio_socket_audio_chemin_assistant(audio_t *a, char *sortie, int capacite)
{
    if (a == NULL || sortie == NULL || capacite <= 0) {
        errno = EINVAL;
        return -1;
    }
    if (!a->chemin_valide) {
        errno = EINVAL;
        return -1;
    }
    const size_t n = strlen(a->chemin);
    if (n >= (size_t)capacite) {
        errno = ENOSPC;
        return -1;
    }
    memcpy(sortie, a->chemin, n + 1);
    return 0;
}

void audio_socket_audio_oublier_fils(void)
{
    struct audio *a = g_instance;
    if (a == NULL || a->createur == getpid() || g_fils_a_oublie)
        return;
    /* Un fils ne doit ni écrire dans la structure partagée, ni annoncer la
       connexion : il se contente de lâcher son mappage et sa copie du
       descripteur. La socket et le .pcm appartiennent à l'assistant, jamais
       à nous : aucun unlink. */
    if (a->anneau != NULL && a->taille_anneau != 0)
        munmap(a->anneau, a->taille_anneau);
    if (a->fd >= 0)
        close(a->fd);
    g_fils_a_oublie = 1;
}

void audio_socket_audio_fermer(audio_t *a)
{
    if (a == NULL)
        return;
    const pid_t moi = getpid();
    if (a->createur == moi) {
        if (a->fd >= 0) {
            /* Adieu au mieux : l'assistant peut déjà être parti. */
            envoyer_trame(a->fd, TRAMES_AUDIO_TYPE_BYE, NULL, 0, instant_ns());
            close(a->fd);
            a->fd = -1;
        }
        if (g_instance == a)
            g_instance = NULL;
    } else if (g_fils_a_oublie) {
        /* Le fils a déjà lâché sa copie de l'anneau et du descripteur. */
        return;
    }
    if (a->anneau != NULL && a->taille_anneau != 0) {
        munmap(a->anneau, a->taille_anneau);
        a->anneau = NULL;
        a->taille_anneau = 0;
    }
    if (a->partage)
        munmap(a, sizeof *a);
    else
        free(a);
}

const char *audio_socket_audio_chemin(audio_t *a)
{
    (void)a;
    return "socket";
}

const char *audio_socket_audio_format(audio_t *a)
{
    (void)a;
    return "FLOAT_LE";
}

const char *audio_socket_audio_derniere_erreur(void)
{
    return g_erreur[0] != '\0' ? g_erreur : NULL;
}
