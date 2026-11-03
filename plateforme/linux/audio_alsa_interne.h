/* Interface interne de audio_alsa.c, réservée aux tests de la plate-forme.
   Ne pas inclure depuis plateforme/audio.h : ces détails d'implémentation
   (construction de chemins, injection des appels système du chemin ioctl)
   ne font pas partie de l'API publique. */
#ifndef ORGANUM_AUDIO_ALSA_INTERNE_H
#define ORGANUM_AUDIO_ALSA_INTERNE_H

#include <stddef.h>

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

#endif
