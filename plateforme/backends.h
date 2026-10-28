/* Implémentations par système des interfaces audio.h et midi.h ; audio.c et
   midi.c choisissent la bonne au lancement (un même binaire cosmopolitan
   tourne sous Linux et sous Windows). */
#ifndef BACKENDS_H
#define BACKENDS_H

#include "audio.h"
#include "midi.h"

#define DECLARER_BACKEND(p)                                                   \
  audio_t *p##_audio_ouvrir(const char *, int, int, int, int);                \
  int p##_audio_ecrire(audio_t *, const float *, int);                        \
  int p##_audio_xruns(audio_t *);                                             \
  void p##_audio_fermer(audio_t *);                                           \
  const char *p##_audio_chemin(audio_t *);                                    \
  const char *p##_audio_format(audio_t *);                                    \
  midi_t *p##_midi_ouvrir(const char *, const char *);                        \
  int p##_midi_fd(midi_t *);                                                  \
  int p##_midi_lire(midi_t *, midi_msg_t *, int);                             \
  int p##_midi_connecter_depuis(midi_t *, int, int);                          \
  int p##_midi_adresse(midi_t *, int *, int *);                               \
  int p##_midi_connecter_tout(midi_t *);                                      \
  void p##_midi_fermer(midi_t *);

DECLARER_BACKEND(alsa)
DECLARER_BACKEND(winmm)

#endif
