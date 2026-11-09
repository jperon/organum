/* Entrée MIDI macOS par socket Unix, dialogue avec un assistant CoreMIDI.
 *
 * CoreMIDI n'est accessible que depuis un binaire Mach-O, hors de l'APE
 * cosmopolitan : un assistant externe ouvre la socket, énumère les sources et
 * écrit les messages reçus en trames normalisées. Ce backend est le client de
 * cette socket. La spécification est dans PROTOCOLE-MIDI.md et le codec pur
 * dans trames_midi.h.
 *
 * Tout ce qui touche la socket (connexion, lecture, écritures de contrôle)
 * reste borné et non bloquant : midi_lire() est appelée dans le fil audio.
 * Le chemin est résolu une seule fois à l'ouverture, jamais par la suite. */
#include <cosmo.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#include "../backends.h"
#include "trames_midi.h"

#define MIDI_SOCKET_MAX_FRAME TRAMES_MIDI_MAX_FRAME_MAX
#define MIDI_SOCKET_LECTURES 4
#define MIDI_SOCKET_TAMPON 256
#define MIDI_SOCKET_MESSAGES 64
#define MIDI_SOCKET_DELAI 1
#define MIDI_SOCKET_DELAI_VERSION 10

enum etat_socket {
    ETAT_ATTENTE = 0, /* pas de connexion ; on réessaie périodiquement */
    ETAT_POIGNEE,     /* connecté, poignée de main en cours */
    ETAT_CONNECTE     /* trames échangées */
};

struct peripherique_socket {
    uint8_t id;
    uint8_t capacites;
    char nom[TRAMES_MIDI_NOM_MAX + 1];
};

struct midi {
    int fd;
    int etat;
    int partage; /* structure en mémoire partagée entre processus */
    /* Processus qui a ouvert la socket : seul celui-ci lit. Les fils de
       requête redbean héritent du descripteur et de cette structure ; un
       recv() chez eux volerait des trames au fil audio, qui seul sait les
       remettre au moteur. */
    pid_t createur;
    int chemin_valide;
    char chemin[TRAMES_MIDI_SUN_PATH_MAX];
    struct timespec prochain_essai;

    uint8_t poignee[TRAMES_MIDI_POIGNEE_TAILLE];
    int poignee_envoyee;
    int poignee_recue;
    uint16_t max_frame;
    struct trame_decodeur decodeur;

    /* Octets lus mais pas encore remis au décodeur (surplus d'un tour). */
    uint8_t entree[MIDI_SOCKET_TAMPON];
    int entree_debut;
    int entree_fin;

    /* 0 : jamais demandé, 1 : demandé, 2 : refusé explicitement.
       Un refus tient jusqu'à midi_connecter_tout(), comme pour ALSA. */
    uint8_t abonnement[256];
    int automatique;
    unsigned long sysex; /* compteur, messages SysEx ignorés en v1 */

    struct peripherique_socket peripheriques[TRAMES_MIDI_PERIPHERIQUES_MAX];
    int nperipheriques;
};

static int adresse_valide(int client, int port)
{
    return client >= 0 && client <= 255 && port >= 0 && port <= 255;
}

static int argument_invalide(void)
{
    errno = EINVAL;
    return -1;
}

static void armer_recul(midi_t *m, int secondes)
{
    clock_gettime(CLOCK_MONOTONIC, &m->prochain_essai);
    m->prochain_essai.tv_sec += secondes;
}

static int echeance_atteinte(const midi_t *m)
{
    struct timespec maintenant;
    clock_gettime(CLOCK_MONOTONIC, &maintenant);
    if (maintenant.tv_sec != m->prochain_essai.tv_sec)
        return maintenant.tv_sec > m->prochain_essai.tv_sec;
    return maintenant.tv_nsec >= m->prochain_essai.tv_nsec;
}

/* Une écriture bornée : jamais d'attente, et EAGAIN devient ENOSPC pour
   l'appelant (Lua ou fil audio). SIGPIPE est ignoré par redbean ; on emploie
   MSG_NOSIGNAL quand il existe pour ne pas en dépendre dans les tests. */
static int ecrire_tout(midi_t *m, const uint8_t *octets, size_t n)
{
    size_t fait = 0;
    while (fait < n) {
        ssize_t w;
#ifdef MSG_NOSIGNAL
        w = send(m->fd, octets + fait, n - fait, MSG_NOSIGNAL);
#else
        w = write(m->fd, octets + fait, n - fait);
#endif
        if (w > 0) {
            fait += (size_t)w;
            continue;
        }
        if (w < 0 && errno == EINTR)
            continue;
        if (w < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            errno = ENOSPC;
            return -1;
        }
        if (w == 0)
            errno = EPIPE;
        return -1;
    }
    return 0;
}

static int envoyer_trame(midi_t *m, uint8_t type, uint8_t flags,
                         const uint8_t *corps, uint16_t longueur)
{
    uint8_t trame[TRAMES_MIDI_ENTETE_TAILLE + 2];
    if (longueur > 2)
        return -1;
    const int n = trame_encoder(trame, sizeof trame, type, flags, corps, longueur);
    if (n < 0)
        return -1;
    return ecrire_tout(m, trame, (size_t)n);
}

static int envoyer_abonnement(midi_t *m, uint8_t id, uint8_t actif)
{
    const uint8_t corps[2] = {id, actif};
    return envoyer_trame(m, TRAMES_MIDI_TYPE_SUBSCRIBE, 0, corps, 2);
}

static void fermer_connexion(midi_t *m)
{
    if (m->fd >= 0)
        close(m->fd);
    m->fd = -1;
    m->etat = ETAT_ATTENTE;
    m->poignee_envoyee = 0;
    m->poignee_recue = 0;
    m->entree_debut = 0;
    m->entree_fin = 0;
    trame_decodeur_init(&m->decodeur, MIDI_SOCKET_MAX_FRAME);
}

/* Rejoue les abonnements mémorisés après une connexion (l'assistant a pu
   redémarrer). Un échec d'écriture n'est pas fatal : la connexion reste. */
static void envoyer_abonnements(midi_t *m)
{
    for (int i = 0; i < 256; ++i)
        if (m->abonnement[i] == 1)
            envoyer_abonnement(m, (uint8_t)i, 1);
}

static int trouver_peripherique(midi_t *m, uint8_t id)
{
    for (int i = 0; i < m->nperipheriques; ++i)
        if (m->peripheriques[i].id == id)
            return i;
    return -1;
}

static void retirer_peripherique(midi_t *m, uint8_t id)
{
    const int i = trouver_peripherique(m, id);
    if (i < 0)
        return;
    for (int j = i + 1; j < m->nperipheriques; ++j)
        m->peripheriques[j - 1] = m->peripheriques[j];
    --m->nperipheriques;
}

/* Une DEVICE_LIST remplace la liste. Une source nouvelle est abonnée d'office
   en mode automatique, sauf si elle a été refusée explicitement. */
static void remplacer_peripheriques(midi_t *m,
                                    const struct peripherique_vue *vues, int n)
{
    m->nperipheriques = 0;
    for (int i = 0; i < n && m->nperipheriques < TRAMES_MIDI_PERIPHERIQUES_MAX;
         ++i) {
        struct peripherique_socket *p = &m->peripheriques[m->nperipheriques++];
        p->id = vues[i].id;
        p->capacites = vues[i].capacites;
        size_t len = vues[i].nom_len;
        if (len > TRAMES_MIDI_NOM_MAX)
            len = TRAMES_MIDI_NOM_MAX;
        memcpy(p->nom, vues[i].nom, len);
        p->nom[len] = '\0';
        if ((p->capacites & TRAMES_MIDI_CAPACITE_SOURCE) && m->automatique &&
            m->abonnement[p->id] == 0) {
            m->abonnement[p->id] = 1;
            envoyer_abonnement(m, p->id, 1);
        }
    }
}

/* DEVICE_EVENT ne porte pas le nom : on ne peut que retirer une source
   disparue ou marquer présente une source déjà connue. */
static void evenement_peripherique(midi_t *m, uint8_t id, uint8_t present)
{
    if (!present) {
        retirer_peripherique(m, id);
        return;
    }
    const int i = trouver_peripherique(m, id);
    if (i >= 0) {
        if ((m->peripheriques[i].capacites & TRAMES_MIDI_CAPACITE_SOURCE) &&
            m->automatique && m->abonnement[id] == 0) {
            m->abonnement[id] = 1;
            envoyer_abonnement(m, id, 1);
        }
        return;
    }
    /* Inconnu : la liste complète viendra plus tard, on ne l'invente pas. */
}

static int traiter_trame(midi_t *m, const struct trame_vue *vue,
                         midi_msg_t *msgs, int count, int max)
{
    switch (vue->type) {
    case TRAMES_MIDI_TYPE_MIDI: {
        if (!trame_midi_valide(vue->corps, vue->longueur))
            break;
        uint8_t statut = vue->corps[0];
        uint8_t d1 = vue->corps[1] & 0x7F;
        uint8_t d2 = vue->longueur >= 3 ? (vue->corps[2] & 0x7F) : 0;
        switch (statut & 0xF0) {
        case 0x90:
            if (d2 == 0)
                statut = (uint8_t)(0x80 | (statut & 0x0F));
            /* fallthrough */
        case 0x80:
        case 0xB0:
        case 0xC0:
            if (count < max)
                msgs[count++] = (midi_msg_t){statut, d1, d2};
            break;
        default:
            break;
        }
        break;
    }
    case TRAMES_MIDI_TYPE_SYSEX:
        ++m->sysex;
        break;
    case TRAMES_MIDI_TYPE_DEVICE_LIST: {
        struct peripherique_vue vues[TRAMES_MIDI_PERIPHERIQUES_MAX];
        const int n = peripheriques_parser(vue->corps, vue->longueur, vues,
                                           TRAMES_MIDI_PERIPHERIQUES_MAX);
        if (n >= 0)
            remplacer_peripheriques(m, vues, n);
        break;
    }
    case TRAMES_MIDI_TYPE_DEVICE_EVENT:
        if (vue->longueur >= 2)
            evenement_peripherique(m, vue->corps[0],
                                   vue->corps[1] != 0);
        break;
    case TRAMES_MIDI_TYPE_PING:
        /* Réponse au mieux : un PONG perdu ne coupe pas la session. */
        envoyer_trame(m, TRAMES_MIDI_TYPE_PONG, 0, NULL, 0);
        break;
    case TRAMES_MIDI_TYPE_PONG:
    case TRAMES_MIDI_TYPE_SUBSCRIBE:
        break;
    case TRAMES_MIDI_TYPE_BYE:
        return -1; /* fermeture propre annoncée */
    default:
        break; /* type inconnu : trame lue puis ignorée */
    }
    return count;
}

/* Avance la machine d'état de la connexion. Renvoie 0, ou 1 si une erreur a
   fermé la connexion (l'appelant peut encore rendre les messages déjà lus). */
static int avancer_connexion(midi_t *m)
{
    if (m->etat == ETAT_ATTENTE) {
        if (!m->chemin_valide || !echeance_atteinte(m))
            return 0;

        int fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd < 0) {
            armer_recul(m, MIDI_SOCKET_DELAI);
            return 0;
        }
        int drapeaux = fcntl(fd, F_GETFL, 0);
        if (drapeaux < 0 || fcntl(fd, F_SETFL, drapeaux | O_NONBLOCK) < 0) {
            close(fd);
            armer_recul(m, MIDI_SOCKET_DELAI);
            return 0;
        }
#ifdef SO_NOSIGPIPE
        /* XNU n'a pas MSG_NOSIGNAL ; redbean ignore déjà SIGPIPE, ceci
           protège aussi un appelant qui ne l'aurait pas fait. */
        {
            int un = 1;
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &un, sizeof un);
        }
#endif

        struct sockaddr_un adresse;
        memset(&adresse, 0, sizeof adresse);
        adresse.sun_family = AF_UNIX;
        memcpy(adresse.sun_path, m->chemin, strlen(m->chemin) + 1);

        if (connect(fd, (struct sockaddr *)&adresse, sizeof adresse) < 0) {
            /* EINPROGRESS : la poignée de main confirmera la connexion. */
            if (errno != EINPROGRESS && errno != EALREADY) {
                close(fd);
                armer_recul(m, MIDI_SOCKET_DELAI);
                return 0;
            }
        }

        m->fd = fd;
        m->etat = ETAT_POIGNEE;
        m->poignee_envoyee = 0;
        m->poignee_recue = 0;
        poignee_encoder(m->poignee, TRAMES_MIDI_STATUT_OK,
                        MIDI_SOCKET_MAX_FRAME);
        trame_decodeur_init(&m->decodeur, MIDI_SOCKET_MAX_FRAME);
    }

    if (m->etat == ETAT_POIGNEE) {
        while (m->poignee_envoyee < TRAMES_MIDI_POIGNEE_TAILLE) {
            const ssize_t w = write(m->fd, m->poignee + m->poignee_envoyee,
                                    TRAMES_MIDI_POIGNEE_TAILLE -
                                        (size_t)m->poignee_envoyee);
            if (w > 0) {
                m->poignee_envoyee += (int)w;
                continue;
            }
            if (w < 0 && errno == EINTR)
                continue;
            if (w < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
                return 0;
            fermer_connexion(m);
            armer_recul(m, MIDI_SOCKET_DELAI);
            return 1;
        }

        while (m->poignee_recue < TRAMES_MIDI_POIGNEE_TAILLE) {
            const ssize_t r = recv(m->fd, m->poignee + m->poignee_recue,
                                   TRAMES_MIDI_POIGNEE_TAILLE -
                                       (size_t)m->poignee_recue,
                                   0);
            if (r > 0) {
                m->poignee_recue += (int)r;
                continue;
            }
            if (r < 0 && errno == EINTR)
                continue;
            if (r < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
                return 0;
            fermer_connexion(m);
            armer_recul(m, MIDI_SOCKET_DELAI);
            return 1;
        }

        struct poignee_vue vue;
        const int code = poignee_decoder(m->poignee, &vue);
        if (code != 1) {
            int delai = MIDI_SOCKET_DELAI;
            if (vue.statut == TRAMES_MIDI_STATUT_VERSION)
                delai = MIDI_SOCKET_DELAI_VERSION;
            fermer_connexion(m);
            armer_recul(m, delai);
            return 1;
        }
        m->max_frame = vue.max_frame;
        if (m->max_frame > MIDI_SOCKET_MAX_FRAME)
            m->max_frame = MIDI_SOCKET_MAX_FRAME;
        trame_decodeur_init(&m->decodeur, m->max_frame);
        m->entree_debut = 0;
        m->entree_fin = 0;
        m->etat = ETAT_CONNECTE;
        envoyer_abonnements(m);
    }
    return 0;
}

midi_t *midi_socket_midi_ouvrir(const char *nom_client, const char *nom_port)
{
    (void)nom_client;
    (void)nom_port;

    /* Mémoire partagée : les processus fils de redbean doivent voir la liste
       des périphériques publiée par le processus principal. Repli calloc. */
    midi_t *m = mmap(NULL, sizeof(midi_t), PROT_READ | PROT_WRITE,
                     MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    int partage = 1;
    if (m == MAP_FAILED) {
        m = (midi_t *)calloc(1, sizeof(midi_t));
        partage = 0;
    }
    if (m == NULL)
        return NULL;
    m->partage = partage;

    m->fd = -1;
    m->etat = ETAT_ATTENTE;
    m->createur = getpid();
    m->max_frame = MIDI_SOCKET_MAX_FRAME;
    trame_decodeur_init(&m->decodeur, MIDI_SOCKET_MAX_FRAME);

    /* Le chemin est figé ici : midi_lire() ne fait jamais de getenv. */
    const char *env = getenv("ORGANUM_MIDI_SOCKET");
    const char *tmpdir = getenv("TMPDIR");
    m->chemin_valide =
        trame_chemin_socket(env, tmpdir, (unsigned long)getuid(), m->chemin,
                            sizeof m->chemin) == 0;
    /* Premier essai au prochain appel, sans attendre une seconde. */
    m->prochain_essai.tv_sec = 0;
    m->prochain_essai.tv_nsec = 0;

    return m;
}

int midi_socket_midi_connecte(midi_t *m)
{
    if (m == NULL)
        return -1;
    return m->etat == ETAT_CONNECTE ? 1 : 0;
}

int midi_socket_midi_chemin(midi_t *m, char *sortie, int capacite)
{
    if (m == NULL || sortie == NULL || capacite <= 0)
        return argument_invalide();
    if (!m->chemin_valide) {
        errno = EINVAL;
        return -1;
    }
    const size_t n = strlen(m->chemin);
    if (n >= (size_t)capacite) {
        errno = ENOSPC;
        return -1;
    }
    memcpy(sortie, m->chemin, n + 1);
    return 0;
}

int midi_socket_midi_fd(midi_t *m)
{
    if (m == NULL)
        return argument_invalide();
    return m->fd;
}

int midi_socket_midi_adresse(midi_t *m, int *client, int *port)
{
    if (m == NULL)
        return argument_invalide();
    if (client)
        *client = 0;
    if (port)
        *port = 0;
    return 0;
}

int midi_socket_midi_connecter_depuis(midi_t *m, int client, int port)
{
    return midi_socket_midi_connecter(m, client, port);
}

int midi_socket_midi_connecter(midi_t *m, int client, int port)
{
    if (m == NULL || !adresse_valide(client, port))
        return argument_invalide();
    m->abonnement[client] = 1;
    if (m->etat != ETAT_CONNECTE || m->fd < 0)
        return 0;
    return envoyer_abonnement(m, (uint8_t)client, 1);
}

int midi_socket_midi_deconnecter(midi_t *m, int client, int port)
{
    if (m == NULL || !adresse_valide(client, port))
        return argument_invalide();
    m->abonnement[client] = 2;
    if (m->etat != ETAT_CONNECTE || m->fd < 0)
        return 0;
    return envoyer_abonnement(m, (uint8_t)client, 0);
}

int midi_socket_midi_connecter_tout(midi_t *m)
{
    if (m == NULL)
        return argument_invalide();
    m->automatique = 1;
    /* Nouveau départ : les refus explicites précédents ne valent plus. */
    memset(m->abonnement, 0, sizeof m->abonnement);
    int n = 0;
    for (int i = 0; i < m->nperipheriques; ++i) {
        struct peripherique_socket *p = &m->peripheriques[i];
        if (!(p->capacites & TRAMES_MIDI_CAPACITE_SOURCE))
            continue;
        m->abonnement[p->id] = 1;
        if (m->etat == ETAT_CONNECTE && m->fd >= 0)
            envoyer_abonnement(m, p->id, 1);
        ++n;
    }
    return n;
}

int midi_socket_midi_ports(midi_t *m, struct midi_port *ports, int max)
{
    if (m == NULL || max < 0 || (ports == NULL && max > 0))
        return argument_invalide();
    int n = 0;
    for (int i = 0; i < m->nperipheriques && n < max; ++i) {
        const struct peripherique_socket *p = &m->peripheriques[i];
        if (!(p->capacites & TRAMES_MIDI_CAPACITE_SOURCE))
            continue;
        struct midi_port *d = &ports[n++];
        memset(d, 0, sizeof(*d));
        d->client = p->id;
        d->port = 0;
        strncpy(d->nom_client, "CoreMIDI", sizeof(d->nom_client) - 1);
        strncpy(d->nom_port, p->nom, sizeof(d->nom_port) - 1);
        d->capacites = p->capacites;
        d->lecture = 1;
        d->abonnement = 1;
        d->generique = 1;
        d->source = 1;
        d->connecte = 1;
    }
    return n;
}

int midi_socket_midi_lire(midi_t *m, midi_msg_t *msgs, int max)
{
    if (m == NULL || msgs == NULL || max <= 0)
        return -1;
    /* Un fils de requête ne lit jamais la socket : il ne saurait pas quoi
       faire du message MIDI et le perdrait. Seul le processus créateur
       (fil audio) consomme les trames, y compris les PING auxquels il
       répond PONG. */
    if (m->createur != getpid())
        return 0;
    if (max > MIDI_SOCKET_MESSAGES)
        max = MIDI_SOCKET_MESSAGES;

    int count = 0;
    int lectures = 0;
    int erreur = 0;

    for (;;) {
        /* Vider d'abord les octets reçus au tour précédent. */
        while (m->entree_debut < m->entree_fin && count < max) {
            struct trame_vue vue;
            size_t consommes = 0;
            const int code = trame_decoder(
                &m->decodeur, m->entree + m->entree_debut,
                (size_t)(m->entree_fin - m->entree_debut), &vue, &consommes);
            if (code == -1) {
                erreur = 1;
                break;
            }
            if (code == 0) {
                m->entree_debut = m->entree_fin;
                break;
            }
            m->entree_debut += (int)consommes;
            const int avant = count;
            count = traiter_trame(m, &vue, msgs, count, max);
            if (count < 0) {
                erreur = 1;
                count = avant;
                break;
            }
        }
        if (erreur)
            break;
        if (count >= max)
            return count; /* surplus conservé pour le tour suivant */

        if (m->etat != ETAT_CONNECTE) {
            if (avancer_connexion(m))
                break;
            if (m->etat != ETAT_CONNECTE)
                return count;
            continue;
        }

        if (lectures >= MIDI_SOCKET_LECTURES)
            break;
        if (m->entree_debut == m->entree_fin) {
            m->entree_debut = 0;
            m->entree_fin = 0;
        }

        const ssize_t r = recv(m->fd, m->entree + m->entree_fin,
                               sizeof m->entree - (size_t)m->entree_fin, 0);
        ++lectures;
        if (r > 0) {
            m->entree_fin += (int)r;
            continue;
        }
        if (r == 0) {
            erreur = 1; /* fin de flux */
            break;
        }
        if (errno == EINTR) {
            --lectures;
            continue;
        }
        if (errno == EAGAIN || errno == EWOULDBLOCK)
            break;
        erreur = 1;
        break;
    }

    if (erreur) {
        fermer_connexion(m);
        armer_recul(m, MIDI_SOCKET_DELAI);
    }
    return count;
}

void midi_socket_midi_fermer(midi_t *m)
{
    if (m == NULL)
        return;
    /* Un fils ne ferme ni n'annonce la connexion du processus principal :
       il se contente d'oublier son propre mappage. */
    if (m->createur == getpid() && m->fd >= 0) {
        /* Adieu au mieux : le pair peut déjà être parti. */
        envoyer_trame(m, TRAMES_MIDI_TYPE_BYE, 0, NULL, 0);
        close(m->fd);
    }
    if (m->partage)
        munmap(m, sizeof(midi_t));
    else
        free(m);
}
