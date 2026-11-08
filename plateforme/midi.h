#ifndef MIDI_H
#define MIDI_H

#ifdef __cplusplus
extern "C" {
#endif

#define MIDI_MAX_PORTS 128

typedef struct midi midi_t;

typedef struct {
    unsigned char statut;
    unsigned char d1;
    unsigned char d2;
} midi_msg_t;

/* Un port du séquenceur du système, tel que midi_ports() le décrit. */
struct midi_port {
    int client, port;             /* adresse du port (client:port) */
    char nom_client[64], nom_port[64];
    unsigned int capacites, type; /* capacités et type ALSA bruts */
    unsigned char lecture;        /* le port peut émettre (CAP_READ) */
    unsigned char ecriture;       /* le port peut recevoir (CAP_WRITE) */
    unsigned char abonnement;     /* abonnement possible (SUBS_READ/WRITE) */
    unsigned char generique;      /* type MIDI_GENERIC */
    unsigned char source;         /* source utilisable par Organum */
    unsigned char destination;    /* destination utilisable par Organum */
    unsigned char connecte;       /* source abonnée à notre port */
    unsigned char organum;        /* c'est notre propre port */
};

midi_t *midi_ouvrir(const char *nom_client, const char *nom_port);
int midi_fd(midi_t *midi);
int midi_lire(midi_t *midi, midi_msg_t *msgs, int max);
int midi_connecter_depuis(midi_t *midi, int client, int port);
int midi_adresse(midi_t *midi, int *client, int *port);
/* Connecte toutes les sources MIDI présentes, puis (via midi_lire) celles
   qui apparaîtront : claviers branchés, accordion, etc. */
int midi_connecter_tout(midi_t *midi);

/* Énumère les ports du système dans « ports » (au plus « max »), avec
   l'état de leur abonnement vers notre port. Renvoie le nombre de ports
   décrits, ou -1 si le séquenceur n'est pas disponible ou si les arguments
   sont invalides (dans ce dernier cas errno = EINVAL). */
int midi_ports(midi_t *midi, struct midi_port *ports, int max);
/* Abonne explicitement la source client:port à notre port. Une connexion
   déjà existante n'est pas une erreur. client et port doivent tenir dans
   l'octet ALSA (0..255), sinon renvoie -1 avec errno = EINVAL. */
int midi_connecter(midi_t *midi, int client, int port);
/* Désabonne client:port et le mémorise pour que la connexion automatique
   ne le rétablisse pas avant le prochain midi_connecter_tout(). Mêmes
   bornes d'adresse que midi_connecter ; 0:1 (annonces du système, qui
   détectent les nouveaux ports) est refusé avec errno = EINVAL. L'adresse
   reste exclue même si un périphérique rebranché réutilise le même
   client:port, jusqu'à la prochaine remise à zéro. */
int midi_deconnecter(midi_t *midi, int client, int port);

void midi_fermer(midi_t *midi);

/* Vrai si un backend MIDI est compilé pour la plate-forme courante. */
int midi_supportee(void);

#ifdef __cplusplus
}
#endif

#endif /* MIDI_H */
