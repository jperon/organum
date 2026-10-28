/* Aiguillage de audio.h vers l'implémentation du système hôte. */
#include <cosmo.h>
#include "backends.h"

#define AIGUILLER(f, ...) (IsWindows() ? winmm_##f(__VA_ARGS__) : alsa_##f(__VA_ARGS__))

audio_t *audio_ouvrir(const char *p, int taux, int canaux, int periode, int nb)
{ return AIGUILLER(audio_ouvrir, p, taux, canaux, periode, nb); }
int audio_ecrire(audio_t *a, const float *e, int n) { return AIGUILLER(audio_ecrire, a, e, n); }
int audio_xruns(audio_t *a) { return AIGUILLER(audio_xruns, a); }
void audio_fermer(audio_t *a) { IsWindows() ? winmm_audio_fermer(a) : alsa_audio_fermer(a); }
const char *audio_chemin(audio_t *a) { return AIGUILLER(audio_chemin, a); }
const char *audio_format(audio_t *a) { return AIGUILLER(audio_format, a); }
