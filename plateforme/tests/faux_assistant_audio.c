/* Faux assistant CoreAudio pour les tests sous Linux.
 *
 * Organum parle à CoreAudio par une socket Unix et un fichier anneau partagé
 * (voir plateforme/macos/audio_socket.c). Ce programme
 * joue le rôle de l'assistant : il crée la socket et le fichier `.pcm`,
 * échange la poignée OAUD, applique AUDIO_CONFIG, répond AUDIO_ACK puis
 * AUDIO_DEVICE, puis consomme l'anneau au rythme simulé du taux annoncé.
 *
 * Il inclut le vrai codec (../macos/trames_audio.h) et le vrai anneau
 * (../macos/anneau_audio.h) : le test éprouve donc l'encodeur, le décodeur et
 * l'anneau réellement utilisés par organum, sans recopie de la
 * spécification.
 *
 * Le temps est celui de la libc native (CLOCK_MONOTONIC) : ce binaire est
 * compilé par le cc de l'hôte, pas par cosmocc, il n'a donc pas le défaut de
 * diviseur TSC de ce dernier sous XNU.
 *
 * Usage :
 *   faux_assistant_audio [--socket CHEMIN] [--attendre-client MS]
 *                        [--tomber-apres MS] [--duree MS]
 *                        [--refuser-version] [--version N]
 *                        [--version-anneau N] [--sans-peripherique]
 *                        [--taux-blocage POURCENT] [--ne-pas-drainer]
 *                        [--rampe] [--device-tilde-apres MS] [--aide]
 *
 * --tomber-apres ferme la connexion puis sort après MS (panne simulée).
 * --duree borne la vie du programme. --refuser-version répond le statut 1.
 * --version N annonce N dans la poignée (simule un assistant ancien) ;
 * --version-anneau N écrit N dans l'en-tête de l'anneau.
 * --sans-peripherique répond ACK statut 2 (aucune sortie). --taux-blocage
 * draine à POURCENT du taux (provoque des overruns chez le producteur) ;
 * --ne-pas-drainer ne consomme rien. --rampe vérifie que les échantillons
 * reçus sont exactement la rampe émise par un producteur synthétique (utile
 * hors intégration organum, dont le signal est de l'audio réel).
 * --device-tilde-apres envoie MS après la poignée un AUDIO_DEVICE dont le
 * nom contient le caractère « ~ » (0x7E, valeur du type BYE) : le client ne
 * doit pas confondre un octet de corps avec une trame de déconnexion.
 *
 * Compilation hôte, sans cosmocc :
 *   cc -O2 -Wall -Wextra -std=c11 -o faux_assistant_audio \
 *      plateforme/tests/faux_assistant_audio.c
 */
#define _POSIX_C_SOURCE 200809L

#include "../macos/anneau_audio.h"
#include "../macos/trames_audio.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
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

#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0
#endif

#define MAX_FRAME 4096
#define TAMPON_LECTURE 512
#define DELAI_POIGNEE 5000
#define ATTENTE_CLIENT_DEFAUT 15000
#define CANAUX 2
#define OCTETS_TRAME (CANAUX * (uint32_t)sizeof(float))
/* Au plus une seconde de trames relues d'un coup (32 Kio). */
#define TRAMES_PAR_LOT 4096u

/* Tolérance de retard du producteur avant de compter un vrai underrun.
 * Bornée par la capacité réelle de l'anneau (2048 trames, ~43 ms à
 * 48 kHz) ; l'ancienne valeur de 32 périodes ne convenait qu'à une fenêtre
 * de 16384 trames. En deçà, un retard n'est pas une famine mais de la gigue
 * d'ordonnancement. Au-delà, le faux assistant recale son horloge simulée :
 * ce n'est pas un consommateur temps réel et il ne doit pas inventer
 * d'underruns quand il manque ses rendez-vous sous charge. */
#define TOLERANCE_PERIODES 32u

static volatile sig_atomic_t arret;

static void sur_signal(int sig)
{
    (void)sig;
    arret = 1;
}

static long long maintenant_ns(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (long long)t.tv_sec * 1000000000LL + t.tv_nsec;
}

static void journal(const char *format, ...)
{
    va_list args;
    va_start(args, format);
    vfprintf(stdout, format, args);
    va_end(args);
    fputc('\n', stdout);
    fflush(stdout);
}

static int ecrire_tout(int fd, const void *octets, size_t n)
{
    const uint8_t *p = octets;
    size_t fait = 0;
    while (fait < n) {
        const ssize_t w = send(fd, p + fait, n - fait, MSG_NOSIGNAL);
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

static int envoyer_trame(int fd, uint8_t type, const uint8_t *corps,
                         uint16_t longueur)
{
    uint8_t trame[TRAMES_ENTETE_TAILLE + TRAMES_AUDIO_CONFIG_TAILLE + 128];
    if (longueur > TRAMES_AUDIO_CONFIG_TAILLE + 128)
        return -1;
    const int n =
        trame_encoder(trame, sizeof trame, type, 0, corps, longueur);
    if (n < 0)
        return -1;
    return ecrire_tout(fd, trame, (size_t)n);
}

/* Lit exactement n octets, en abandonnant proprement sur signal. Renvoie 0,
 * -1 sur fin/erreur, -2 sur expiration du délai. */
static int lire_exact(int fd, uint8_t *sortie, size_t n, long delai_ms)
{
    const long long echeance = maintenant_ns() + (long long)delai_ms * 1000000LL;
    size_t fait = 0;
    while (fait < n) {
        if (arret)
            return -1;
        const long long reste = echeance - maintenant_ns();
        if (reste <= 0)
            return -2;
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
/* Fichier anneau partagé                                             */
/* ------------------------------------------------------------------ */

static struct anneau_entete *preparer_anneau(const char *chemin,
                                             size_t *taille)
{
    const size_t total = sizeof(struct anneau_entete) +
                         (size_t)ANNEAU_AUDIO_CAPACITE_MAX * OCTETS_TRAME;
    /* O_TRUNC récupère un fichier laissé par un assistant tué par SIGKILL. */
    const int fd = open(chemin, O_RDWR | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) {
        fprintf(stderr, "faux_assistant_audio : ouverture de %s : %s\n",
                chemin, strerror(errno));
        return NULL;
    }
    if (fchmod(fd, 0600) < 0)
        perror("faux_assistant_audio : fchmod");
    if (ftruncate(fd, (off_t)total) < 0) {
        fprintf(stderr, "faux_assistant_audio : ftruncate de %s : %s\n",
                chemin, strerror(errno));
        close(fd);
        return NULL;
    }
    void *p = mmap(NULL, total, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (p == MAP_FAILED) {
        fprintf(stderr, "faux_assistant_audio : mmap de %s : %s\n", chemin,
                strerror(errno));
        return NULL;
    }
    struct anneau_entete *e = (struct anneau_entete *)p;
    if (anneau_initialiser(e, CANAUX, OCTETS_TRAME, 48000, 512,
                           ANNEAU_AUDIO_CAPACITE_MAX, 1) != 0) {
        fprintf(stderr, "faux_assistant_audio : anneau invalide\n");
        munmap(e, total);
        return NULL;
    }
    *taille = total;
    journal("anneau créé : %s (%zu octets, capacité %u trames)", chemin,
            total, (unsigned)ANNEAU_AUDIO_CAPACITE_MAX);
    return e;
}

/* ------------------------------------------------------------------ */
/* Socket d'écoute                                                    */
/* ------------------------------------------------------------------ */

static int ouvrir_ecoute(const char *chemin)
{
    /* Sonde : un assistant vivant garde sa socket, une socket périmée est
       remplacée. Même règle que le faux assistant MIDI et le vrai. */
    struct sockaddr_un adresse;
    memset(&adresse, 0, sizeof adresse);
    adresse.sun_family = AF_UNIX;
    memcpy(adresse.sun_path, chemin, strlen(chemin) + 1);

    const int sonde = socket(AF_UNIX, SOCK_STREAM, 0);
    if (sonde < 0) {
        perror("faux_assistant_audio : socket");
        return -1;
    }
    if (connect(sonde, (struct sockaddr *)&adresse, sizeof adresse) == 0) {
        close(sonde);
        fprintf(stderr,
                "faux_assistant_audio : un autre assistant écoute déjà sur %s\n",
                chemin);
        return -3;
    }
    const int erreur = errno;
    close(sonde);
    if (erreur != ENOENT && erreur != ECONNREFUSED) {
        fprintf(stderr, "faux_assistant_audio : sonde de %s : %s\n", chemin,
                strerror(erreur));
        return -1;
    }

    umask(077);
    if (unlink(chemin) < 0 && errno != ENOENT) {
        perror("faux_assistant_audio : unlink");
        return -1;
    }

    const int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        perror("faux_assistant_audio : socket");
        return -1;
    }
    if (bind(fd, (struct sockaddr *)&adresse, sizeof adresse) < 0) {
        perror("faux_assistant_audio : bind");
        close(fd);
        return -1;
    }
    if (chmod(chemin, 0600) < 0)
        perror("faux_assistant_audio : chmod");
    if (listen(fd, 4) < 0) {
        perror("faux_assistant_audio : listen");
        close(fd);
        unlink(chemin);
        return -1;
    }
    return fd;
}

/* ------------------------------------------------------------------ */
/* Session avec un client organum                                     */
/* ------------------------------------------------------------------ */

struct session {
    int fd;
    struct trame_decodeur decodeur;
    uint8_t tampon[TAMPON_LECTURE];
    size_t debut, fin;

    int configure;
    uint32_t taux;
    uint32_t periode;

    /* Horloge de lecture simulée : démarre à la première trame reçue, pour
       qu'une recréation de moteur (quelques secondes) ne soit pas comptée
       comme une famine. */
    long long base_ns;
    long long dernier_journal_ns;
    long long device_tilde_echeance;
    int device_tilde_envoye;
    uint64_t consomme;      /* trames du rythme simulé (silence compris) */
    uint64_t pings, pongs;  /* PING envoyés, PONG reçus */
    int rampe_attendue;
    uint64_t non_fini;
    uint64_t non_nuls;
    uint64_t controle;      /* FNV-1a des échantillons relus */
};

struct options {
    int refuser_version;
    /* Version annoncée dans la poignée (0 = version du codec). Un test peut
       ainsi simuler un assistant resté à une version antérieure. */
    int version_annoncee;
    /* Version écrite dans l'en-tête de l'anneau (0 = version du codec) :
       éprouve le refus d'un anneau hétérogène côté organum. */
    int version_anneau;
    int sans_peripherique;
    int ne_pas_drainer;
    int rampe;
    int taux_blocage; /* 0 = 100 % */
    long device_tilde_apres; /* < 0 : jamais */
    /* Simule un rappel CoreAudio déjà actif avant l'ACK : consomme N blocs
       de `periode` trames dans l'anneau, donc du silence tant que le
       producteur n'a pas démarré. Sert à éprouver le drapeau `demarre` :
       sans lui, ces lectures comptent des underruns de démarrage. */
    int consommer_avant_ack;
    long consommer_apres_config; /* < 0 : jamais */
};

static struct anneau_entete *g_anneau;

static uint64_t g_trames_drainees;
static unsigned g_configs;
static uint64_t g_pings;
static uint64_t g_pongs;
static uint64_t g_non_fini;
static int g_connexions;

static int verifier_echantillons(struct session *s, const float *t,
                                 size_t trames)
{
    int ok = 1;
    for (size_t i = 0; i < trames; ++i) {
        for (int c = 0; c < CANAUX; ++c) {
            const float v = t[2 * i + c];
            if (v != v || v > 1.0e30f || v < -1.0e30f) {
                ++s->non_fini;
                ++g_non_fini;
                ok = 0;
            } else if (v != 0.0f) {
                ++s->non_nuls;
            }
            if (s->rampe_attendue) {
                /* Rampe synthétique : index absolu dans le flux simulé. */
                const uint64_t n = s->consomme + i;
                const float attendu =
                    (float)(((n * 2 + (uint64_t)c) * 7u) % 1000u) / 1000.0f -
                    0.5f;
                if (v != attendu)
                    ok = 0;
            }
        }
    }
    if (!ok && !s->rampe_attendue)
        journal("erreur : échantillon non fini détecté");
    return ok;
}

/* Consomme l'anneau au rythme simulé. Renvoie 0, ou -1 sur incohérence du
 * fichier. */
static int drainer(struct session *s, const struct options *o,
                   long long maintenant)
{
    if (!s->configure || o->ne_pas_drainer)
        return 0;

    if (s->base_ns == 0) {
        if (anneau_disponible(g_anneau) == 0)
            return 0;
        s->base_ns = maintenant;
        s->dernier_journal_ns = maintenant;
    }

    long long ecoule = maintenant - s->base_ns;
    if (ecoule < 0)
        ecoule = 0; /* saut d'horloge vers l'arrière : repartir de zéro */
    uint64_t objectif =
        (uint64_t)ecoule * (uint64_t)s->taux / 1000000000ULL;
    if (o->taux_blocage > 0)
        objectif = objectif * (uint64_t)o->taux_blocage / 100ULL;
    if (objectif <= s->consomme)
        return 0;

    uint64_t deficit = objectif - s->consomme;
    const uint64_t dispo = anneau_disponible(g_anneau);
    const uint64_t capacite = g_anneau->capacite;
    /* La tolérance ne peut pas dépasser la fenêtre réelle de l'anneau :
       depuis la négociation à quelques périodes (2048 trames), une
       tolérance de 32 périodes laisserait le consommateur courir plus loin
       que la capacité, puis relire un arriéré qui n'existe pas. */
    uint64_t tolerance = (uint64_t)TOLERANCE_PERIODES * (uint64_t)s->periode;
    if (tolerance > capacite)
        tolerance = capacite;
    if (deficit > tolerance) {
        /* Le faux assistant n'est pas temps réel : sous charge (le
           martèlement de l'API), il peut manquer ses rendez-vous puis
           vouloir rattraper un arriéré qui n'a jamais existé côté
           CoreAudio. Recaler l'horloge simulée au lieu d'inventer des
           underruns ; le contrôle `--consommer-avant-ack` éprouve, lui, le
           vrai comptage. */
        const uint64_t pourcent = o->taux_blocage > 0
                                      ? (uint64_t)o->taux_blocage
                                      : 100u;
        const uint64_t effectif = (uint64_t)s->taux * pourcent / 100u;
        /* Trace du temps de lecture abandonné : le script de cadence rejette
           alors la fenêtre (machine chargée, faux assistant non temps réel)
           au lieu de prendre un simple retard d'ordonnancement pour une
           dérive de cadence du produit. */
        journal("recalage: perdu=%llu", (unsigned long long)deficit);
        if (effectif != 0)
            s->base_ns = maintenant -
                         (long long)(s->consomme * 1000000000ULL / effectif);
        return 0;
    }
    uint64_t demander = deficit;
    if (deficit <= tolerance) {
        /* Le producteur peut être en retard d'une ou deux périodes sans que
           ce soit une famine : ne rien demander tant qu'il n'a pas écrit. */
        if (dispo < deficit)
            return 0;
    }
    if (demander > capacite)
        demander = capacite;
    if (demander > TRAMES_PAR_LOT)
        demander = TRAMES_PAR_LOT;

    static float tampon[TRAMES_PAR_LOT * CANAUX];
    const size_t lues = anneau_lire(g_anneau, tampon, (size_t)demander);
    if (!verifier_echantillons(s, tampon, lues))
        return -1;
    for (size_t i = 0; i < lues; ++i) {
        const uint8_t *octets = (const uint8_t *)&tampon[2 * i];
        for (size_t k = 0; k < OCTETS_TRAME; ++k) {
            s->controle ^= octets[k];
            s->controle *= 1099511628211ULL;
        }
    }
    g_trames_drainees += lues;
    /* Une famine est comptée par anneau_lire : la trame manquante vaut du
       silence au rythme simulé, donc l'objectif est atteint malgré tout. */
    if (lues < demander)
        s->consomme += demander;
    else
        s->consomme += lues;

    /* Bilan partiel une fois par seconde : le script peut comparer le drain
       réel aux compteurs de l'anneau sans attendre la fin de session. */
    if (maintenant - s->dernier_journal_ns >= 1000000000LL) {
        s->dernier_journal_ns = maintenant;
        journal("drain: total=%llu underruns=%llu overruns=%llu non_fini=%llu",
                (unsigned long long)g_trames_drainees,
                (unsigned long long)atomic_load(&g_anneau->underruns),
                (unsigned long long)atomic_load(&g_anneau->overruns),
                (unsigned long long)s->non_fini);
    }
    return 0;
}

static int envoyer_ping(struct session *s)
{
    if (envoyer_trame(s->fd, TRAMES_AUDIO_TYPE_PING, NULL, 0) < 0)
        return -1;
    ++s->pings;
    ++g_pings;
    journal("PING envoyé");
    return 0;
}

static int repondre_config(struct session *s, const struct options *o,
                           const uint8_t *corps, uint16_t longueur)
{
    struct audio_config_vue cfg;
    if (audio_config_decoder(corps, longueur, &cfg) != 0) {
        journal("erreur : AUDIO_CONFIG malformé");
        return -1;
    }
    journal("CONFIG reçue : génération=%u taux=%u période=%u canaux=%u "
            "format=%u capacité=%u octets=%u",
            cfg.generation, cfg.taux, cfg.periode, cfg.canaux, cfg.format,
            cfg.capacite, cfg.octets);

    ++g_configs;
    uint8_t statut = TRAMES_AUDIO_STATUT_OK;
    if (cfg.format != TRAMES_AUDIO_FORMAT_FLOAT32_ENTRELACE ||
        cfg.canaux != CANAUX ||
        cfg.octets != (uint32_t)(cfg.capacite * CANAUX * sizeof(float)))
        statut = TRAMES_AUDIO_STATUT_FORMAT;
    else if (cfg.capacite < ANNEAU_AUDIO_CAPACITE_MIN ||
             cfg.capacite > ANNEAU_AUDIO_CAPACITE_MAX ||
             (cfg.capacite & (cfg.capacite - 1u)) != 0 ||
             cfg.periode == 0 || cfg.periode > cfg.capacite)
        statut = TRAMES_AUDIO_STATUT_CONFIG;
    if (o->sans_peripherique)
        statut = TRAMES_AUDIO_STATUT_AUCUNE_SORTIE;

    if (statut == TRAMES_AUDIO_STATUT_OK) {
        /* L'en-tête est réécrit avant l'acquittement : le backend a mappé le
           fichier, il verra la configuration retenue. Comme le vrai
           assistant, on honore la capacité négociée (et non le maximum). */
        if (anneau_initialiser(g_anneau, CANAUX, OCTETS_TRAME, cfg.taux,
                               cfg.periode, cfg.capacite,
                               cfg.generation) != 0) {
            journal("erreur : anneau non initialisable");
            return -1;
        }
        if (o->version_anneau != 0)
            g_anneau->version = (uint32_t)o->version_anneau;
        s->configure = 1;
        s->taux = cfg.taux;
        s->periode = cfg.periode;
        s->base_ns = 0;
        s->consomme = 0;
        s->controle = 1469598103934665603ULL;

        if (o->consommer_avant_ack > 0 &&
            o->consommer_apres_config >= 0 &&
            g_configs >= (unsigned)o->consommer_apres_config) {
            static float silence[TRAMES_PAR_LOT * CANAUX];
            for (int i = 0; i < o->consommer_avant_ack; ++i) {
                const size_t lues = anneau_lire(g_anneau, silence,
                                                (size_t)cfg.periode);
                journal("consommation avant ACK : %u trames lues "
                        "(demarre=%u, underruns=%llu)",
                        (unsigned)lues,
                        (unsigned)atomic_load(&g_anneau->demarre),
                        (unsigned long long)atomic_load(&g_anneau->underruns));
            }
        }
    }

    /* Un PING avant l'ACK éprouve le chemin de contrôle pendant la poignée :
       organum doit répondre exactement un PONG, y compris depuis un fil de
       requête hérité (leçon du MIDI). */
    if (envoyer_ping(s) < 0)
        return -1;

    struct audio_ack_vue ack;
    ack.statut = statut;
    ack.generation = cfg.generation;
    ack.taux = cfg.taux;
    ack.periode = cfg.periode;
    ack.capacite = cfg.capacite;
    uint8_t corps_ack[TRAMES_AUDIO_ACK_TAILLE];
    const int n = audio_ack_encoder(corps_ack, sizeof corps_ack, &ack);
    if (n < 0 || envoyer_trame(s->fd, TRAMES_AUDIO_TYPE_ACK, corps_ack,
                               (uint16_t)n) < 0)
        return -1;
    journal("ACK envoyé : statut=%u taux=%u période=%u capacité=%u", statut,
            cfg.taux, cfg.periode, (unsigned)cfg.capacite);
    if (statut != TRAMES_AUDIO_STATUT_OK) {
        /* Organum va fermer : rester à l'écoute du prochain essai. */
        return 0;
    }

    static const char nom[] = "Sortie fictive";
    struct audio_device_vue dev;
    dev.nom_len = (uint8_t)(sizeof nom - 1);
    dev.nom = (const uint8_t *)nom;
    dev.taux_natif = cfg.taux;
    dev.latence_us = 10000;
    uint8_t corps_dev[TRAMES_AUDIO_DEVICE_TAILLE_MIN + 128];
    const int nd =
        audio_device_encoder(corps_dev, sizeof corps_dev, &dev);
    if (nd < 0 || envoyer_trame(s->fd, TRAMES_AUDIO_TYPE_DEVICE, corps_dev,
                                (uint16_t)nd) < 0)
        return -1;
    journal("DEVICE envoyé : %s (taux natif %u, latence %u µs)", nom,
            dev.taux_natif, dev.latence_us);
    return 0;
}

/* Traite toutes les trames complètes déjà présentes. Renvoie 0, ou -1 sur
 * BYE, erreur de décodage ou demande d'arrêt. */
static int traiter_trames(struct session *s, const struct options *o)
{
    for (;;) {
        struct trame_vue vue;
        size_t consommes = 0;
        const int code = trame_decoder(&s->decodeur, s->tampon + s->debut,
                                       s->fin - s->debut, &vue, &consommes);
        if (code < 0)
            return -1;
        if (code == 0) {
            s->debut = s->fin = 0;
            return 0;
        }
        s->debut += consommes;
        switch (vue.type) {
        case TRAMES_AUDIO_TYPE_CONFIG:
            if (repondre_config(s, o, vue.corps, vue.longueur) < 0)
                return -1;
            break;
        case TRAMES_AUDIO_TYPE_PING:
            journal("PING reçu, PONG envoyé");
            if (envoyer_trame(s->fd, TRAMES_AUDIO_TYPE_PONG, NULL, 0) < 0)
                return -1;
            break;
        case TRAMES_AUDIO_TYPE_PONG:
            ++s->pongs;
            ++g_pongs;
            journal("PONG reçu");
            break;
        case TRAMES_AUDIO_TYPE_STOP:
            journal("STOP reçu");
            return -1;
        case TRAMES_AUDIO_TYPE_BYE:
            journal("BYE reçu d'organum");
            return -1;
        default:
            break; /* type inconnu : ignoré, comme le prescrit le protocole */
        }
        if (s->debut == s->fin)
            s->debut = s->fin = 0;
    }
}

/* Sert un client jusqu'à sa fermeture. Renvoie 0 pour continuer à écouter,
 * 1 pour sortir (--tomber-apres). */
static int servir_client(int fd, const struct options *o, long tomber_apres,
                         long long fin_globale)
{
    struct session s;
    memset(&s, 0, sizeof s);
    s.fd = fd;
    trame_decodeur_init(&s.decodeur, MAX_FRAME);
    s.controle = 1469598103934665603ULL;
    s.rampe_attendue = o->rampe;
    if (o->device_tilde_apres >= 0)
        s.device_tilde_echeance =
            maintenant_ns() + (long long)o->device_tilde_apres * 1000000LL;

    uint8_t poignee[TRAMES_AUDIO_POIGNEE_TAILLE];
    const int lu = lire_exact(fd, poignee, sizeof poignee, DELAI_POIGNEE);
    if (lu != 0) {
        fprintf(stderr, "faux_assistant_audio : poignée %s\n",
                lu == -2 ? "non reçue dans le délai" : "interrompue");
        return 0;
    }

    struct poignee_vue vue;
    const int code = poignee_audio_decoder(poignee, &vue);
    uint8_t reponse[TRAMES_AUDIO_POIGNEE_TAILLE];
    if (code != 1 || o->refuser_version) {
        const uint8_t statut = (code == -2 || o->refuser_version)
                                   ? TRAMES_AUDIO_STATUT_FORMAT
                                   : TRAMES_AUDIO_STATUT_INTERNE;
        poignee_audio_encoder(reponse, statut, MAX_FRAME);
        ecrire_tout(fd, reponse, sizeof reponse);
        journal("poignée refusée (code %d, statut envoyé %u)", code, statut);
        return 0;
    }

    journal("poignée acceptée (client version %u, max_frame %u)", vue.version,
            vue.max_frame);
    poignee_audio_encoder(reponse, TRAMES_AUDIO_STATUT_OK, MAX_FRAME);
    if (o->version_annoncee != 0)
        reponse[4] = (uint8_t)o->version_annoncee;
    if (ecrire_tout(fd, reponse, sizeof reponse) < 0)
        return 0;

    ++g_connexions;
    const long long chute = tomber_apres >= 0
                                ? maintenant_ns() + (long long)tomber_apres * 1000000LL
                                : 0;

    for (;;) {
        if (arret)
            break;
        const long long maintenant = maintenant_ns();
        if (fin_globale != 0 && maintenant >= fin_globale)
            break;
        if (chute != 0 && maintenant >= chute) {
            journal("chute demandée après %ld ms", tomber_apres);
            break;
        }
        if (s.device_tilde_echeance != 0 && !s.device_tilde_envoye &&
            maintenant >= s.device_tilde_echeance) {
            static const char nom_tilde[] = "Sortie ~ fictive (0x7E)";
            struct audio_device_vue dev;
            dev.nom_len = (uint8_t)(sizeof nom_tilde - 1);
            dev.nom = (const uint8_t *)nom_tilde;
            dev.taux_natif = s.taux;
            dev.latence_us = 10000;
            uint8_t corps[TRAMES_AUDIO_DEVICE_TAILLE_MIN + 128];
            const int nd = audio_device_encoder(corps, sizeof corps, &dev);
            if (nd < 0 ||
                envoyer_trame(fd, TRAMES_AUDIO_TYPE_DEVICE, corps,
                              (uint16_t)nd) < 0)
                break;
            s.device_tilde_envoye = 1;
            journal("DEVICE tilde envoyé : %s", nom_tilde);
        }
        if (traiter_trames(&s, o) < 0)
            break;
        if (drainer(&s, o, maintenant) < 0)
            break;

        struct pollfd p = {fd, POLLIN, 0};
        int r;
        do {
            r = poll(&p, 1, 2);
        } while (r < 0 && errno == EINTR && !arret);
        if (r < 0)
            break;
        if (r == 0)
            continue;
        if (s.debut == s.fin)
            s.debut = s.fin = 0;
        const ssize_t n = recv(fd, s.tampon + s.fin,
                               sizeof s.tampon - s.fin, 0);
        if (n == 0)
            break;
        if (n < 0) {
            if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)
                continue;
            break;
        }
        s.fin += (size_t)n;
    }

    journal("session terminée : taux=%u trames=%llu pings=%llu pongs=%llu "
            "non_fini=%llu non_nuls=%llu controle=%016llx underruns=%llu "
            "overruns=%llu",
            s.taux, (unsigned long long)s.consomme,
            (unsigned long long)s.pings, (unsigned long long)s.pongs,
            (unsigned long long)s.non_fini, (unsigned long long)s.non_nuls,
            (unsigned long long)s.controle,
            (unsigned long long)atomic_load(&g_anneau->underruns),
            (unsigned long long)atomic_load(&g_anneau->overruns));
    journal("drain: total=%llu underruns=%llu overruns=%llu",
            (unsigned long long)g_trames_drainees,
            (unsigned long long)atomic_load(&g_anneau->underruns),
            (unsigned long long)atomic_load(&g_anneau->overruns));
    return chute != 0 && maintenant_ns() >= chute ? 1 : 0;
}

static int attendre_client(int ecoute, long long echeance)
{
    for (;;) {
        if (arret)
            return -1;
        const long long reste = echeance - maintenant_ns();
        if (reste < 0)
            return 0; /* délai écoulé sans client */
        long ms = (long)(reste / 1000000LL) + 1;
        if (ms > 200)
            ms = 200;
        struct pollfd p = {ecoute, POLLIN, 0};
        const int r = poll(&p, 1, (int)ms);
        if (r < 0) {
            if (errno == EINTR)
                continue;
            return -1;
        }
        if (r > 0)
            return 1;
    }
}

static void aide(const char *programme)
{
    printf("Usage : %s [--socket CHEMIN] [--attendre-client MS]\n"
           "       [--tomber-apres MS] [--duree MS] [--refuser-version]\n"
           "       [--version N] [--version-anneau N]\n"
           "       [--sans-peripherique] [--taux-blocage POURCENT]\n"
           "       [--ne-pas-drainer] [--rampe]\n"
           "       [--device-tilde-apres MS]\n"
           "       [--consommer-avant-ack N] [--consommer-apres-config N]\n",
           programme);
}

int main(int argc, char **argv)
{
    const char *socket_arg = NULL;
    long attendre = ATTENTE_CLIENT_DEFAUT;
    long tomber_apres = -1;
    long duree = -1;
    struct options o;
    memset(&o, 0, sizeof o);
    o.taux_blocage = 0;
    o.device_tilde_apres = -1;
    o.consommer_apres_config = -1;

    for (int i = 1; i < argc; ++i) {
        if (strcmp(argv[i], "--socket") == 0 && i + 1 < argc) {
            socket_arg = argv[++i];
        } else if (strcmp(argv[i], "--attendre-client") == 0 && i + 1 < argc) {
            attendre = strtol(argv[++i], NULL, 10);
            if (attendre < 0)
                goto invalide;
        } else if (strcmp(argv[i], "--tomber-apres") == 0 && i + 1 < argc) {
            tomber_apres = strtol(argv[++i], NULL, 10);
            if (tomber_apres < 0)
                goto invalide;
        } else if (strcmp(argv[i], "--duree") == 0 && i + 1 < argc) {
            duree = strtol(argv[++i], NULL, 10);
            if (duree < 0)
                goto invalide;
        } else if (strcmp(argv[i], "--taux-blocage") == 0 && i + 1 < argc) {
            o.taux_blocage = (int)strtol(argv[++i], NULL, 10);
            if (o.taux_blocage <= 0 || o.taux_blocage > 100)
                goto invalide;
        } else if (strcmp(argv[i], "--refuser-version") == 0) {
            o.refuser_version = 1;
        } else if (strcmp(argv[i], "--version") == 0 && i + 1 < argc) {
            o.version_annoncee = (int)strtol(argv[++i], NULL, 10);
            if (o.version_annoncee <= 0 || o.version_annoncee > 255)
                goto invalide;
        } else if (strcmp(argv[i], "--version-anneau") == 0 &&
                   i + 1 < argc) {
            o.version_anneau = (int)strtol(argv[++i], NULL, 10);
            if (o.version_anneau <= 0 || o.version_anneau > 255)
                goto invalide;
        } else if (strcmp(argv[i], "--sans-peripherique") == 0) {
            o.sans_peripherique = 1;
        } else if (strcmp(argv[i], "--ne-pas-drainer") == 0) {
            o.ne_pas_drainer = 1;
        } else if (strcmp(argv[i], "--rampe") == 0) {
            o.rampe = 1;
        } else if (strcmp(argv[i], "--device-tilde-apres") == 0 &&
                   i + 1 < argc) {
            o.device_tilde_apres = strtol(argv[++i], NULL, 10);
            if (o.device_tilde_apres < 0)
                goto invalide;
        } else if (strcmp(argv[i], "--consommer-avant-ack") == 0 &&
                   i + 1 < argc) {
            o.consommer_avant_ack = (int)strtol(argv[++i], NULL, 10);
            if (o.consommer_avant_ack < 0)
                goto invalide;
        } else if (strcmp(argv[i], "--consommer-apres-config") == 0 &&
                   i + 1 < argc) {
            o.consommer_apres_config = strtol(argv[++i], NULL, 10);
            if (o.consommer_apres_config < 0)
                goto invalide;
        } else if (strcmp(argv[i], "--aide") == 0 ||
                   strcmp(argv[i], "-h") == 0) {
            aide(argv[0]);
            return 0;
        } else {
        invalide:
            fprintf(stderr, "faux_assistant_audio : argument invalide « %s »\n",
                    argv[i]);
            aide(argv[0]);
            return 2;
        }
    }

    char chemin[TRAMES_SUN_PATH_MAX];
    if (socket_arg != NULL) {
        if (socket_arg[0] == '\0' || strlen(socket_arg) >= sizeof chemin) {
            fprintf(stderr,
                    "faux_assistant_audio : chemin --socket invalide\n");
            return 2;
        }
        strcpy(chemin, socket_arg);
    } else if (trame_chemin_socket_nom(
                   getenv("ORGANUM_AUDIO_SOCKET"), getenv("TMPDIR"),
                   (unsigned long)getuid(), "organum-audio-", chemin,
                   sizeof chemin) != 0) {
        fprintf(stderr,
                "faux_assistant_audio : chemin de socket par défaut "
                "invalide\n");
        return 2;
    }

    const size_t n = strlen(chemin);
    if (n + sizeof ".pcm" > sizeof chemin) {
        fprintf(stderr, "faux_assistant_audio : chemin trop long pour .pcm\n");
        return 2;
    }
    char chemin_pcm[TRAMES_SUN_PATH_MAX + 8];
    memcpy(chemin_pcm, chemin, n);
    memcpy(chemin_pcm + n, ".pcm", sizeof ".pcm");

    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = sur_signal;
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);

    size_t taille_anneau = 0;
    g_anneau = preparer_anneau(chemin_pcm, &taille_anneau);
    if (g_anneau == NULL)
        return 1;

    const int ecoute = ouvrir_ecoute(chemin);
    if (ecoute < 0) {
        munmap(g_anneau, taille_anneau);
        return ecoute == -3 ? 3 : 1;
    }
    journal("écoute sur %s", chemin);

    const long long debut = maintenant_ns();
    const long long echeance_client = debut + (long long)attendre * 1000000LL;
    const long long fin_globale =
        duree >= 0 ? debut + (long long)duree * 1000000LL : 0;

    int client_recu = 0;
    int code_sortie = 0;
    while (!arret) {
        if (fin_globale != 0 && maintenant_ns() >= fin_globale)
            break;
        int pret;
        if (!client_recu) {
            pret = attendre_client(ecoute, echeance_client);
            if (pret == 0) {
                fprintf(stderr,
                        "faux_assistant_audio : aucun client avant %ld ms\n",
                        attendre);
                code_sortie = 4;
                break;
            }
        } else {
            struct pollfd p = {ecoute, POLLIN, 0};
            pret = poll(&p, 1, 100);
            if (pret < 0) {
                if (errno == EINTR)
                    continue;
                code_sortie = 1;
                break;
            }
            if (pret == 0)
                continue;
        }
        if (pret < 0) {
            code_sortie = 1;
            break;
        }

        const int fd = accept(ecoute, NULL, NULL);
        if (fd < 0) {
            if (errno == EINTR)
                continue;
            perror("faux_assistant_audio : accept");
            code_sortie = 1;
            break;
        }
        journal("client connecté");
        client_recu = 1;
        const int r = servir_client(fd, &o, tomber_apres, fin_globale);
        close(fd);
        if (r == 1)
            break;
    }

    journal("bilan : connexions=%d trames=%llu pings=%llu pongs=%llu "
            "non_fini=%llu underruns=%llu overruns=%llu",
            g_connexions, (unsigned long long)g_trames_drainees,
            (unsigned long long)g_pings, (unsigned long long)g_pongs,
            (unsigned long long)g_non_fini,
            (unsigned long long)atomic_load(&g_anneau->underruns),
            (unsigned long long)atomic_load(&g_anneau->overruns));
    close(ecoute);
    unlink(chemin);
    munmap(g_anneau, taille_anneau);
    return arret ? 0 : code_sortie;
}
