#ifndef MIDI_H
#define MIDI_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct midi midi_t;

typedef struct {
    unsigned char statut;
    unsigned char d1;
    unsigned char d2;
} midi_msg_t;

midi_t *midi_ouvrir(const char *nom_client, const char *nom_port);
int midi_fd(midi_t *midi);
int midi_lire(midi_t *midi, midi_msg_t *msgs, int max);
int midi_connecter_depuis(midi_t *midi, int client, int port);
int midi_adresse(midi_t *midi, int *client, int *port);
/* Connecte toutes les sources MIDI présentes, puis (via midi_lire) celles
   qui apparaîtront : claviers branchés, accordion, etc. */
int midi_connecter_tout(midi_t *midi);
void midi_fermer(midi_t *midi);

#ifdef __cplusplus
}
#endif

#endif /* MIDI_H */
