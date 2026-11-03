/* Interface interne de audio_alsa.c, réservée aux tests de la plate-forme.
   Ne pas inclure depuis plateforme/audio.h : ces détails d'implémentation
   (construction de chemins, injection des appels système du chemin ioctl)
   ne font pas partie de l'API publique. */
#ifndef ORGANUM_AUDIO_ALSA_INTERNE_H
#define ORGANUM_AUDIO_ALSA_INTERNE_H

#include <stddef.h>

#include "../audio.h"

/* Construit « répertoire/nom » sans slash final redoublé. Renvoie 0 si le
   chemin ne tient pas dans le tampon (troncature). */
int alsa_chemin_dans_repertoire(char *chemin, size_t taille,
				const char *repertoire, const char *nom);

/* Construit le chemin /dev/snd/pcmC<carte>D<dev>p depuis « hw:carte,dev ».
   Un format invalide se replie sur /dev/snd/pcmC0D0p. Renvoie 0 si le
   résultat ne tient pas dans le tampon. */
int alsa_construire_chemin_hw(const char *nom, char *chemin, size_t taille);

/* Appels système utilisés par le chemin ioctl. En production, les pointeurs
   valent open/fcntl/close/ioctl ; les tests les remplacent le temps d'un
   appel à alsa_audio_ouvrir(). Passer NULL rétablit les fonctions réelles. */
struct alsa_systeme {
	int (*sys_open)(const char *, int, ...);
	int (*sys_fcntl)(int, int, ...);
	int (*sys_close)(int);
	int (*sys_ioctl)(int, unsigned long, ...);
};

void alsa_audio_injecter_systeme(const struct alsa_systeme *systeme);

/* Fonctions libasound utilisées par la boucle d'écriture, remplaçables par
   les tests. En production, l'injection vaut NULL et les symboles réellement
   chargés servent. Les signatures évitent les types ALSA internes. */
struct alsa_libasound {
	long (*pcm_writei)(void *, const void *, unsigned long);
	int (*pcm_wait)(void *, int);
	int (*pcm_recover)(void *, int, int);
};

void alsa_audio_injecter_libasound(const struct alsa_libasound *systeme);

/* Contexte factice du chemin libasound pour les tests d'écriture (aucun PCM
   ouvert). fmt : 0 = S16_LE, 1 = S32_LE, 2 = FLOAT_LE. */
audio_t *alsa_audio_creer_pour_test(int canaux, int periode, int fmt);

/* Aligne PIPEWIRE_LATENCY sur « periode/taux » pour le PCM « default ».
   Renvoie 1 si la variable a été définie, 0 sinon (déjà définie, autre PCM,
   paramètres invalides). */
int alsa_configurer_latence_pipewire(const char *nom, int periode, int taux);

#endif
