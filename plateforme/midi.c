/* Aiguillage de midi.h vers l'implémentation du système hôte. */
#include <cosmo.h>
#include "backends.h"

#define AIGUILLER(f, ...) (IsWindows() ? winmm_##f(__VA_ARGS__) : alsa_##f(__VA_ARGS__))

midi_t *midi_ouvrir(const char *c, const char *p) { return AIGUILLER(midi_ouvrir, c, p); }
int midi_fd(midi_t *m) { return AIGUILLER(midi_fd, m); }
int midi_lire(midi_t *m, midi_msg_t *msgs, int max) { return AIGUILLER(midi_lire, m, msgs, max); }
int midi_connecter_depuis(midi_t *m, int c, int p) { return AIGUILLER(midi_connecter_depuis, m, c, p); }
int midi_adresse(midi_t *m, int *c, int *p) { return AIGUILLER(midi_adresse, m, c, p); }
int midi_connecter_tout(midi_t *m) { return AIGUILLER(midi_connecter_tout, m); }
void midi_fermer(midi_t *m) { IsWindows() ? winmm_midi_fermer(m) : alsa_midi_fermer(m); }
