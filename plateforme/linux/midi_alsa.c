#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <sys/poll.h>

#include "../backends.h"
#include "asequencer_min.h"
#if defined(__COSMOPOLITAN__)
#include <cosmo.h>
#endif

struct midi {
    int fd;
    int client;
    int port;
    int automatique; /* connecter les sources qui apparaissent */
};

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

    midi_t *m = (midi_t *)calloc(1, sizeof(midi_t));
    if (m == NULL) {
        return NULL;
    }

    m->fd = open("/dev/snd/seq", O_RDWR | O_NONBLOCK);
    if (m->fd < 0) {
        free(m);
        return NULL;
    }

    /* Get client ID */
    if (ioctl(m->fd, SNDRV_SEQ_IOCTL_CLIENT_ID, &m->client) < 0) {
        close(m->fd);
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
    if (ioctl(m->fd, SNDRV_SEQ_IOCTL_SET_CLIENT_INFO, &cinfo) < 0) {
        close(m->fd);
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
    if (ioctl(m->fd, SNDRV_SEQ_IOCTL_CREATE_PORT, &pinfo) < 0) {
        close(m->fd);
        free(m);
        return NULL;
    }
    m->port = pinfo.addr.port;

    return m;
}

int alsa_midi_fd(midi_t *midi)
{
    if (midi == NULL) {
        return -1;
    }
    return midi->fd;
}

int alsa_midi_adresse(midi_t *midi, int *client, int *port)
{
    if (midi == NULL) {
        return -1;
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
    if (midi == NULL) {
        return -1;
    }

    struct snd_seq_port_subscribe subs;
    memset(&subs, 0, sizeof(subs));
    subs.sender.client = client;
    subs.sender.port = port;
    subs.dest.client = midi->client;
    subs.dest.port = midi->port;
    subs.flags = 0;
    subs.queue = 0;

    if (ioctl(midi->fd, SNDRV_SEQ_IOCTL_SUBSCRIBE_PORT, &subs) < 0) {
        return -1;
    }
    return 0;
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

static void connecter_port(midi_t *m, int client, int port)
{
    struct snd_seq_port_info p;
    memset(&p, 0, sizeof(p));
    p.addr.client = client;
    p.addr.port = port;
    if (ioctl(m->fd, SNDRV_SEQ_IOCTL_GET_PORT_INFO, &p) == 0 && source_midi(m, &p))
        alsa_midi_connecter_depuis(m, client, port); /* déjà connecté : EBUSY, sans effet */
}

int alsa_midi_connecter_tout(midi_t *m)
{
    if (m == NULL)
        return -1;
    /* Annonces du système (0:1) : nous préviennent des nouveaux ports. */
    alsa_midi_connecter_depuis(m, 0, 1);
    m->automatique = 1;

    int n = 0;
    struct snd_seq_client_info c;
    memset(&c, 0, sizeof(c));
    c.client = -1;
    while (ioctl(m->fd, SNDRV_SEQ_IOCTL_QUERY_NEXT_CLIENT, &c) == 0) {
        struct snd_seq_port_info p;
        memset(&p, 0, sizeof(p));
        p.addr.client = c.client;
        p.addr.port = -1;
        while (ioctl(m->fd, SNDRV_SEQ_IOCTL_QUERY_NEXT_PORT, &p) == 0)
            if (source_midi(m, &p) && alsa_midi_connecter_depuis(m, p.addr.client, p.addr.port) == 0)
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
            connecter_port(midi, ev.data.addr.client, ev.data.addr.port);
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
        close(midi->fd);
    }
    free(midi);
}
