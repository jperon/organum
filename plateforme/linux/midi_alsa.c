#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <stdatomic.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/poll.h>

#include "../backends.h"
#include "asequencer_min.h"
#include "midi_alsa_interne.h"
#if defined(__COSMOPOLITAN__)
#include <cosmo.h>
#endif

#define MAX_EXCLUSIONS 128

struct midi {
    int fd;
    int client;
    int port;
    int automatique; /* connecter les sources qui apparaissent */
    int partage;     /* structure en mémoire partagée entre processus */
    /* Adresses déconnectées explicitement : la connexion automatique les
       ignore jusqu'au prochain midi_connecter_tout(). La structure est en
       mémoire partagée et la liste en anneau sans verrou : le processus de
       la fenêtre (issu d'un fork) peut y ajouter une adresse pendant que
       le fil audio du processus principal la lit. Un verrou serait risqué
       au fork, qui n'en copie qu'un état éventuellement tenu. */
    atomic_uint seq_exclusions;
    struct {
        atomic_uint seq; /* 0 = case libre ; numéro croissant d'écriture */
        atomic_int client;
        atomic_int port;
    } exclusions[MAX_EXCLUSIONS];
};

/* Appels système remplaçables par les tests. */
static struct midi_alsa_systeme systeme = { open, close, ioctl };

void alsa_midi_injecter_systeme(const struct midi_alsa_systeme *s)
{
    if (s) {
        systeme = *s;
    } else {
        systeme.sys_open = open;
        systeme.sys_close = close;
        systeme.sys_ioctl = ioctl;
    }
}

/* Un client et un port du séquenceur tiennent chacun sur un octet. Sans
   cette borne, 256:0 serait tronqué en 0:0 et abonnerait le mauvais port. */
static int adresse_valide(int client, int port)
{
    return client >= 0 && client <= 255 && port >= 0 && port <= 255;
}

/* L'adresse 0:1 est le port d'annonces du système, auquel on s'abonne pour
   recevoir les PORT_START. Le désabonner couperait la détection des
   nouveaux ports : midi_deconnecter() le refuse. */
static int adresse_annonces(int client, int port)
{
    return client == 0 && port == 1;
}

static int argument_invalide(void)
{
    errno = EINVAL;
    return -1;
}

/* Une case d'exclusion est active si elle a été publiée dans le dernier
   anneau. Le numéro est une génération croissante, pas un simple indice :
   la case d'indice q % MAX_EXCLUSIONS est recyclée toutes les
   MAX_EXCLUSIONS écritures. Si q > seq, l'entrée a été publiée par un autre
   processus après notre lecture de seq_exclusions : elle est récente, donc
   active. La comparer par soustraction non signée la ferait passer pour
   périmée à cause du rebouclage. */
static int exclusion_active(unsigned seq, unsigned q)
{
    if (q == 0)
        return 0;
    if (q > seq)
        return 1;
    return (unsigned)(seq - q) < MAX_EXCLUSIONS;
}

static int adresse_exclue(midi_t *m, int client, int port)
{
    unsigned seq = atomic_load_explicit(&m->seq_exclusions, memory_order_acquire);
    for (int i = 0; i < MAX_EXCLUSIONS; ++i) {
        unsigned q = atomic_load_explicit(&m->exclusions[i].seq, memory_order_acquire);
        if (!exclusion_active(seq, q))
            continue;
        if (atomic_load_explicit(&m->exclusions[i].client, memory_order_relaxed) == client &&
            atomic_load_explicit(&m->exclusions[i].port, memory_order_relaxed) == port)
            return 1;
    }
    return 0;
}

static void exclure(midi_t *m, int client, int port)
{
    if (adresse_exclue(m, client, port))
        return;
    unsigned seq = atomic_fetch_add_explicit(&m->seq_exclusions, 1,
                                             memory_order_acq_rel) + 1;
    int i = (int)(seq % MAX_EXCLUSIONS);
    atomic_store_explicit(&m->exclusions[i].client, client, memory_order_relaxed);
    atomic_store_explicit(&m->exclusions[i].port, port, memory_order_relaxed);
    /* Le numéro est publié en dernier : une case lue avec son nouveau
       numéro contient déjà l'adresse complète. */
    atomic_store_explicit(&m->exclusions[i].seq, seq, memory_order_release);
}

static void autoriser(midi_t *m, int client, int port)
{
    /* Retire l'adresse si elle est encore présente. Un écrivain concurrent
       peut réutiliser la case : le CAS sur le numéro évite alors d'effacer
       une entrée qui ne nous appartient plus. */
    for (int essai = 0; essai < 4; ++essai) {
        unsigned seq = atomic_load_explicit(&m->seq_exclusions, memory_order_acquire);
        int retire = 0;
        for (int i = 0; i < MAX_EXCLUSIONS; ++i) {
            unsigned q = atomic_load_explicit(&m->exclusions[i].seq, memory_order_acquire);
            if (!exclusion_active(seq, q))
                continue;
            if (atomic_load_explicit(&m->exclusions[i].client, memory_order_relaxed) != client ||
                atomic_load_explicit(&m->exclusions[i].port, memory_order_relaxed) != port)
                continue;
            if (atomic_compare_exchange_strong_explicit(&m->exclusions[i].seq, &q, 0,
                                                         memory_order_acq_rel,
                                                         memory_order_acquire)) {
                retire = 1;
                break;
            }
        }
        if (!retire)
            return;
    }
}

static void oublier_exclusions(midi_t *m)
{
    /* Avance d'un anneau entier : toutes les cases déjà écrites deviennent
       périmées, sans les effacer une à une. */
    atomic_fetch_add_explicit(&m->seq_exclusions, MAX_EXCLUSIONS, memory_order_acq_rel);
}

void alsa_midi_tester_exclure_future(midi_t *m, int client, int port)
{
    if (m == NULL || !adresse_valide(client, port))
        return;
    unsigned seq = atomic_load_explicit(&m->seq_exclusions, memory_order_relaxed) + 1;
    int i = (int)(seq % MAX_EXCLUSIONS);
    atomic_store_explicit(&m->exclusions[i].client, client, memory_order_relaxed);
    atomic_store_explicit(&m->exclusions[i].port, port, memory_order_relaxed);
    atomic_store_explicit(&m->exclusions[i].seq, seq, memory_order_release);
}

static int abonner(midi_t *m, int client, int port)
{
    struct snd_seq_port_subscribe subs;
    memset(&subs, 0, sizeof(subs));
    subs.sender.client = client;
    subs.sender.port = port;
    subs.dest.client = m->client;
    subs.dest.port = m->port;
    if (systeme.sys_ioctl(m->fd, SNDRV_SEQ_IOCTL_SUBSCRIBE_PORT, &subs) < 0) {
        /* Déjà abonné : ce n'est pas un échec pour l'appelant. */
        if (errno == EBUSY || errno == EEXIST)
            return 0;
        return -1;
    }
    return 0;
}

static int desabonner(midi_t *m, int client, int port)
{
    struct snd_seq_port_subscribe subs;
    memset(&subs, 0, sizeof(subs));
    subs.sender.client = client;
    subs.sender.port = port;
    subs.dest.client = m->client;
    subs.dest.port = m->port;
    if (systeme.sys_ioctl(m->fd, SNDRV_SEQ_IOCTL_UNSUBSCRIBE_PORT, &subs) < 0) {
        /* Déjà déconnecté : même résultat attendu. EINVAL n'est pas masqué :
           il signalerait un argument invalide, pas une absence. */
        if (errno == ENOENT)
            return 0;
        return -1;
    }
    return 0;
}

static int est_connecte(midi_t *m, int client, int port)
{
    struct snd_seq_port_subscribe subs;
    memset(&subs, 0, sizeof(subs));
    subs.sender.client = client;
    subs.sender.port = port;
    subs.dest.client = m->client;
    subs.dest.port = m->port;
    return systeme.sys_ioctl(m->fd, SNDRV_SEQ_IOCTL_GET_SUBSCRIPTION, &subs) == 0;
}

midi_t *alsa_midi_ouvrir(const char *nom_client, const char *nom_port)
{
#if defined(__COSMOPOLITAN__)
    if (!IsLinux())
        return NULL;
#elif !defined(__linux__)
    return NULL;
#endif

    if (nom_client == NULL) {
        nom_client = "Orgue";
    }
    if (nom_port == NULL) {
        nom_port = "entree";
    }

    /* Mémoire partagée : les processus fils de redbean (fenêtre native)
       héritent le descripteur et doivent aussi partager la liste des
       adresses déconnectées. Repli sur calloc si mmap échoue. */
    midi_t *m = mmap(NULL, sizeof(midi_t), PROT_READ | PROT_WRITE,
                     MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    int partage = 1;
    if (m == MAP_FAILED) {
        m = (midi_t *)calloc(1, sizeof(midi_t));
        partage = 0;
    }
    if (m == NULL) {
        return NULL;
    }
    m->partage = partage;

    m->fd = systeme.sys_open("/dev/snd/seq", O_RDWR | O_NONBLOCK);
    if (m->fd < 0) {
        if (partage)
            munmap(m, sizeof(midi_t));
        else
            free(m);
        return NULL;
    }

    /* Get client ID */
    if (systeme.sys_ioctl(m->fd, SNDRV_SEQ_IOCTL_CLIENT_ID, &m->client) < 0) {
        systeme.sys_close(m->fd);
        if (partage)
            munmap(m, sizeof(midi_t));
        else
            free(m);
        return NULL;
    }

    /* Set client info */
    struct snd_seq_client_info cinfo;
    memset(&cinfo, 0, sizeof(cinfo));
    cinfo.client = m->client;
    cinfo.type = 1; /* USER_CLIENT : le noyau refuse un type différent */
    strncpy(cinfo.name, nom_client, sizeof(cinfo.name) - 1);
    cinfo.name[sizeof(cinfo.name) - 1] = '\0';
    if (systeme.sys_ioctl(m->fd, SNDRV_SEQ_IOCTL_SET_CLIENT_INFO, &cinfo) < 0) {
        systeme.sys_close(m->fd);
        if (partage)
            munmap(m, sizeof(midi_t));
        else
            free(m);
        return NULL;
    }

    /* Create port */
    struct snd_seq_port_info pinfo;
    memset(&pinfo, 0, sizeof(pinfo));
    pinfo.addr.client = m->client;
    pinfo.addr.port = -1;
    strncpy(pinfo.name, nom_port, sizeof(pinfo.name) - 1);
    pinfo.name[sizeof(pinfo.name) - 1] = '\0';
    pinfo.capability = SNDRV_SEQ_PORT_CAP_WRITE | SNDRV_SEQ_PORT_CAP_SUBS_WRITE;
    pinfo.type = SNDRV_SEQ_PORT_TYPE_MIDI_GENERIC | SNDRV_SEQ_PORT_TYPE_APPLICATION;
    pinfo.midi_channels = 16;
    if (systeme.sys_ioctl(m->fd, SNDRV_SEQ_IOCTL_CREATE_PORT, &pinfo) < 0) {
        systeme.sys_close(m->fd);
        if (partage)
            munmap(m, sizeof(midi_t));
        else
            free(m);
        return NULL;
    }
    m->port = pinfo.addr.port;

    return m;
}

int alsa_midi_fd(midi_t *midi)
{
    if (midi == NULL) {
        return argument_invalide();
    }
    return midi->fd;
}

int alsa_midi_adresse(midi_t *midi, int *client, int *port)
{
    if (midi == NULL) {
        return argument_invalide();
    }
    if (client) {
        *client = midi->client;
    }
    if (port) {
        *port = midi->port;
    }
    return 0;
}

int alsa_midi_connecter_depuis(midi_t *midi, int client, int port)
{
    if (midi == NULL || !adresse_valide(client, port))
        return argument_invalide();
    return abonner(midi, client, port);
}


/* Une source à laquelle se connecter : port lisible et abonnable d'un autre
   client, hors système (0) et « Midi Through » (14), qui ne font que relayer. */
static int source_midi(midi_t *m, const struct snd_seq_port_info *p)
{
    unsigned caps = SNDRV_SEQ_PORT_CAP_READ | SNDRV_SEQ_PORT_CAP_SUBS_READ;
    if (p->addr.client == m->client || p->addr.client == 0 || p->addr.client == 14)
        return 0;
    if ((p->capability & caps) != caps || (p->capability & SNDRV_SEQ_PORT_CAP_NO_EXPORT))
        return 0;
    return (p->type & SNDRV_SEQ_PORT_TYPE_MIDI_GENERIC_) != 0;
}

int alsa_midi_connecter_automatique(midi_t *m, int client, int port)
{
    if (m == NULL || !adresse_valide(client, port) ||
        (client == m->client && port == m->port))
        return 0;
    if (adresse_exclue(m, client, port))
        return 0;

    struct snd_seq_port_info p;
    memset(&p, 0, sizeof(p));
    p.addr.client = client;
    p.addr.port = port;
    if (systeme.sys_ioctl(m->fd, SNDRV_SEQ_IOCTL_GET_PORT_INFO, &p) < 0 ||
        !source_midi(m, &p))
        return 0;
    if (abonner(m, client, port) < 0) /* déjà connecté : EBUSY, sans effet */
        return 0;
    /* Entre le premier test et l'abonnement, le processus de la fenêtre a
       pu enregistrer une déconnexion explicite. On la respecte en annulant
       l'abonnement qui vient d'être créé. */
    if (adresse_exclue(m, client, port)) {
        desabonner(m, client, port);
        return 0;
    }
    return 1;
}

int alsa_midi_connecter(midi_t *m, int client, int port)
{
    if (m == NULL || !adresse_valide(client, port))
        return argument_invalide();
    /* Une connexion explicite lève une éventuelle exclusion. */
    autoriser(m, client, port);
    return abonner(m, client, port);
}

int alsa_midi_deconnecter(midi_t *m, int client, int port)
{
    if (m == NULL || !adresse_valide(client, port))
        return argument_invalide();
    if (client == m->client && port == m->port)
        return argument_invalide();
    if (adresse_annonces(client, port))
        return argument_invalide();
    /* Mémorisé avant le désabonnement : même si l'ioctl échoue parce que
       le port a disparu, il ne doit pas être reconnecté à son retour.
       L'adresse reste exclue après un rebranchement qui réutiliserait le
       même numéro de client et de port, jusqu'à midi_connecter_tout(). */
    exclure(m, client, port);
    return desabonner(m, client, port);
}

int alsa_midi_ports(midi_t *m, struct midi_port *ports, int max)
{
    if (m == NULL || max < 0 || (ports == NULL && max > 0))
        return argument_invalide();
    if (max == 0)
        return 0;

    int n = 0, premier = 1;
    struct snd_seq_client_info c;
    memset(&c, 0, sizeof(c));
    c.client = -1;
    while (systeme.sys_ioctl(m->fd, SNDRV_SEQ_IOCTL_QUERY_NEXT_CLIENT, &c) == 0) {
        premier = 0;
        struct snd_seq_port_info p;
        memset(&p, 0, sizeof(p));
        p.addr.client = c.client;
        p.addr.port = -1;
        while (systeme.sys_ioctl(m->fd, SNDRV_SEQ_IOCTL_QUERY_NEXT_PORT, &p) == 0) {
            if (n >= max)
                return n;
            /* Le noyau termine ses noms, mais on ne dépend pas de l'ioctl
               pour la terminaison. */
            c.name[sizeof(c.name) - 1] = '\0';
            p.name[sizeof(p.name) - 1] = '\0';
            struct midi_port *d = &ports[n++];
            memset(d, 0, sizeof(*d));
            d->client = p.addr.client;
            d->port = p.addr.port;
            snprintf(d->nom_client, sizeof(d->nom_client), "%s", c.name);
            snprintf(d->nom_port, sizeof(d->nom_port), "%s", p.name);
            d->capacites = p.capability;
            d->type = p.type;
            d->lecture = (p.capability & SNDRV_SEQ_PORT_CAP_READ) != 0;
            d->ecriture = (p.capability & SNDRV_SEQ_PORT_CAP_WRITE) != 0;
            d->abonnement = (p.capability &
                             (SNDRV_SEQ_PORT_CAP_SUBS_READ | SNDRV_SEQ_PORT_CAP_SUBS_WRITE)) != 0;
            d->generique = (p.type & SNDRV_SEQ_PORT_TYPE_MIDI_GENERIC_) != 0;
            d->source = source_midi(m, &p);
            d->destination = p.addr.client != m->client &&
                             (p.capability & (SNDRV_SEQ_PORT_CAP_WRITE |
                                              SNDRV_SEQ_PORT_CAP_SUBS_WRITE)) ==
                                 (SNDRV_SEQ_PORT_CAP_WRITE | SNDRV_SEQ_PORT_CAP_SUBS_WRITE) &&
                             !(p.capability & SNDRV_SEQ_PORT_CAP_NO_EXPORT);
            d->organum = p.addr.client == m->client;
            d->connecte = !d->organum && est_connecte(m, p.addr.client, p.addr.port);
        }
    }
    /* Une première requête qui échoue signifie que le séquenceur ne répond
       pas ; un échec après quelques clients est une disparition de client,
       sans conséquence sur la liste déjà remplie. */
    if (premier)
        return -1;
    return n;
}

int alsa_midi_connecter_tout(midi_t *m)
{
    if (m == NULL)
        return argument_invalide();
    /* Nouveau départ : les déconnexions explicites précédentes ne valent
       plus, la connexion automatique redevient complète. */
    oublier_exclusions(m);
    /* Annonces du système (0:1) : nous préviennent des nouveaux ports. */
    abonner(m, 0, 1);
    m->automatique = 1;

    int n = 0;
    struct snd_seq_client_info c;
    memset(&c, 0, sizeof(c));
    c.client = -1;
    while (systeme.sys_ioctl(m->fd, SNDRV_SEQ_IOCTL_QUERY_NEXT_CLIENT, &c) == 0) {
        struct snd_seq_port_info p;
        memset(&p, 0, sizeof(p));
        p.addr.client = c.client;
        p.addr.port = -1;
        while (systeme.sys_ioctl(m->fd, SNDRV_SEQ_IOCTL_QUERY_NEXT_PORT, &p) == 0)
            if (alsa_midi_connecter_automatique(m, p.addr.client, p.addr.port))
                n++;
    }
    return n;
}

int alsa_midi_lire(midi_t *midi, midi_msg_t *msgs, int max)
{
    if (midi == NULL || msgs == NULL || max <= 0) {
        return -1;
    }

    int count = 0;
    while (count < max) {
        struct snd_seq_event ev;
        ssize_t r = read(midi->fd, &ev, sizeof(ev));
        if (r < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                break;
            }
            return -1;
        }
        if ((size_t)r < sizeof(ev)) {
            break;
        }

        if (ev.type == SNDRV_SEQ_EVENT_NOTEON) {
            unsigned char ch = ev.data.note.channel & 0x0F;
            unsigned char vel = ev.data.note.velocity;
            if (vel == 0) {
                /* note on with velocity 0 -> note off */
                msgs[count].statut = 0x80 | ch;
                msgs[count].d1 = ev.data.note.note & 0x7F;
                msgs[count].d2 = 0x00;
            } else {
                msgs[count].statut = 0x90 | ch;
                msgs[count].d1 = ev.data.note.note & 0x7F;
                msgs[count].d2 = vel & 0x7F;
            }
            count++;
        } else if (ev.type == SNDRV_SEQ_EVENT_NOTEOFF) {
            unsigned char ch = ev.data.note.channel & 0x0F;
            msgs[count].statut = 0x80 | ch;
            msgs[count].d1 = ev.data.note.note & 0x7F;
            msgs[count].d2 = ev.data.note.velocity & 0x7F;
            count++;
        } else if (ev.type == SNDRV_SEQ_EVENT_CONTROLLER) {
            unsigned char ch = ev.data.control.channel & 0x0F;
            msgs[count].statut = 0xB0 | ch;
            msgs[count].d1 = ev.data.control.param & 0x7F;
            msgs[count].d2 = ev.data.control.value & 0x7F;
            count++;
        } else if (ev.type == SNDRV_SEQ_EVENT_PGMCHANGE) {
            unsigned char ch = ev.data.control.channel & 0x0F;
            msgs[count].statut = 0xC0 | ch;
            msgs[count].d1 = ev.data.control.value & 0x7F;
            msgs[count].d2 = 0x00;
            count++;
        } else if (ev.type == SNDRV_SEQ_EVENT_PORT_START && midi->automatique) {
            alsa_midi_connecter_automatique(midi, ev.data.addr.client, ev.data.addr.port);
        }
    }

    return count;
}

void alsa_midi_fermer(midi_t *midi)
{
    if (midi == NULL) {
        return;
    }
    if (midi->fd >= 0) {
        systeme.sys_close(midi->fd);
    }
    if (midi->partage)
        munmap(midi, sizeof(midi_t));
    else
        free(midi);
}
