/* Implémentations par système des interfaces audio.h et midi.h ; audio.c et
   midi.c choisissent la bonne au lancement (un même binaire cosmopolitan
   tourne sous Linux et sous Windows). */
#ifndef BACKENDS_H
#define BACKENDS_H

#include <stdint.h>

#include "audio.h"
#include "midi.h"

#define DECLARER_BACKEND(p)                                                   \
  audio_t *p##_audio_ouvrir(const char *, int, int, int, int);                \
  int p##_audio_ecrire(audio_t *, const float *, int);                        \
  int p##_audio_xruns(audio_t *);                                             \
  void p##_audio_fermer(audio_t *);                                           \
  const char *p##_audio_chemin(audio_t *);                                    \
  const char *p##_audio_format(audio_t *);                                    \
  const char *p##_audio_derniere_erreur(void);                                \
  int p##_audio_perdue(audio_t *);                                            \
  void p##_audio_oublier_fils(void);                                          \
  midi_t *p##_midi_ouvrir(const char *, const char *);                        \
  int p##_midi_fd(midi_t *);                                                  \
  int p##_midi_lire(midi_t *, midi_msg_t *, int);                             \
  int p##_midi_connecter_depuis(midi_t *, int, int);                          \
  int p##_midi_adresse(midi_t *, int *, int *);                               \
  int p##_midi_connecter_tout(midi_t *);                                      \
  int p##_midi_ports(midi_t *, struct midi_port *, int);                      \
  int p##_midi_connecter(midi_t *, int, int);                                 \
  int p##_midi_deconnecter(midi_t *, int, int);                               \
  void p##_midi_fermer(midi_t *);

/* Backend audio socket macOS (assistant CoreAudio externe). */
#define DECLARER_BACKEND_AUDIO_SOCKET(p)                                      \
  audio_t *p##_audio_ouvrir(const char *, int, int, int, int);                \
  int p##_audio_ecrire(audio_t *, const float *, int);                        \
  int p##_audio_xruns(audio_t *);                                             \
  void p##_audio_fermer(audio_t *);                                           \
  const char *p##_audio_chemin(audio_t *);                                    \
  const char *p##_audio_format(audio_t *);                                    \
  const char *p##_audio_derniere_erreur(void);                                \
  int p##_audio_perdue(audio_t *);                                            \
  void p##_audio_oublier_fils(void);                                          \
  int p##_audio_connecte(audio_t *);                                          \
  uint64_t p##_audio_trames_jouees(audio_t *);                                \
  int p##_audio_chemin_assistant(audio_t *, char *, int);

/* Backend MIDI seul (l'assistant macOS n'apporte pas d'audio). */
#define DECLARER_BACKEND_MIDI(p)                                              \
  midi_t *p##_midi_ouvrir(const char *, const char *);                        \
  int p##_midi_fd(midi_t *);                                                  \
  int p##_midi_lire(midi_t *, midi_msg_t *, int);                             \
  int p##_midi_connecter_depuis(midi_t *, int, int);                          \
  int p##_midi_adresse(midi_t *, int *, int *);                               \
  int p##_midi_connecter_tout(midi_t *);                                      \
  int p##_midi_ports(midi_t *, struct midi_port *, int);                      \
  int p##_midi_connecter(midi_t *, int, int);                                 \
  int p##_midi_deconnecter(midi_t *, int, int);                               \
  void p##_midi_fermer(midi_t *);

DECLARER_BACKEND(alsa)
DECLARER_BACKEND(winmm)
DECLARER_BACKEND_MIDI(midi_socket)
DECLARER_BACKEND_AUDIO_SOCKET(audio_socket)

/* Interrogation propre au backend socket ; midi.c ne l'appelle que sous XNU
   ou quand ORGANUM_MIDI_SOCKET l'impose, jamais pour ALSA/WinMM. */
int midi_socket_midi_connecte(midi_t *);
int midi_socket_midi_chemin(midi_t *, char *, int);

#endif
