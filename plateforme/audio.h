#ifndef AUDIO_H
#define AUDIO_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct audio audio_t;

audio_t *audio_ouvrir(const char *peripherique, int taux, int canaux, int periode, int nb_periodes);
int audio_ecrire(audio_t *audio, const float *entrelace, int trames);
int audio_xruns(audio_t *audio);
void audio_fermer(audio_t *audio);
const char *audio_chemin(audio_t *audio);
const char *audio_format(audio_t *audio);
/* Dernière erreur de chargement de libasound ou d'ouverture du PCM, ou NULL. */
const char *audio_derniere_erreur(void);

#ifdef __cplusplus
}
#endif

#endif /* AUDIO_H */
