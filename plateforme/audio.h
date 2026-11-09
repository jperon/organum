#ifndef AUDIO_H
#define AUDIO_H

#include <stdint.h>

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
/* Vrai si un backend audio est compilé pour la plate-forme courante
   (ALSA, WinMM ou socket macOS). */
int audio_supportee(void);

/* Vrai si le backend audio socket est celui de la plate-forme (XNU), ou si
   ORGANUM_AUDIO_SOCKET le force pour un test sous Linux. Faux sous Windows
   même si la variable est posée. */
int audio_socket_actif(void);
/* Vrai si ORGANUM_AUDIO_SOCKET (non vide) impose le backend socket. */
int audio_socket_imposee(void);

/* Vrai si l'assistant audio a disparu (EOF, BYE ou arrêt de l'anneau). */
int audio_perdue(audio_t *audio);
/* 1 si l'assistant du backend socket est connecté, 0 sinon (y compris hors
   backend socket). */
int audio_connecte(audio_t *audio);
/* Dans un fils après fork : oublier l'anneau et le descripteur hérités du
   backend socket, sans toucher au flux du parent. Sans objet ailleurs. */
void audio_oublier_fils(void);
/* Trames réellement jouées par l'assistant, ou 0 hors backend socket. */
uint64_t audio_trames_jouees(audio_t *audio);
/* Chemin de la socket de l'assistant, copié dans sortie (capacite octets,
   NUL compris). Renvoie 0, ou -1 hors backend socket / si le chemin ne tient
   pas. */
int audio_chemin_assistant(audio_t *audio, char *sortie, int capacite);

#ifdef __cplusplus
}
#endif

#endif /* AUDIO_H */
