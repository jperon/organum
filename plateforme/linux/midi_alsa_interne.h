/* Interface interne de midi_alsa.c, réservée aux tests de la plate-forme.
   L'énumération et les abonnements passent par des ioctl ALSA ; les tests
   remplacent ces appels pour exercer la logique sans séquenceur réel. */
#ifndef ORGANUM_MIDI_ALSA_INTERNE_H
#define ORGANUM_MIDI_ALSA_INTERNE_H

#include "../midi.h"

struct midi_alsa_systeme {
	int (*sys_open)(const char *, int, ...);
	int (*sys_close)(int);
	int (*sys_ioctl)(int, unsigned long, ...);
};

void alsa_midi_injecter_systeme(const struct midi_alsa_systeme *systeme);

/* Connexion automatique d'un port qui vient d'apparaître (événement
   PORT_START) : filtre les sources, respecte les adresses exclues par
   midi_deconnecter(). Renvoie 1 si le port est (ou était déjà) connecté. */
int alsa_midi_connecter_automatique(midi_t *midi, int client, int port);

/* Réservé aux tests : publie une exclusion avec la génération suivant la
   valeur courante, comme un autre processus qui écrirait juste après la
   lecture de seq_exclusions (cas q > seq). */
void alsa_midi_tester_exclure_future(midi_t *midi, int client, int port);

#endif
