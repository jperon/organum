/* Vérifie la construction des chemins de la couche ALSA : répertoire de
   libasound et périphérique ioctl /dev/snd/pcmC... Aucun accès à /dev/snd
   ni à libasound : seules les fonctions pures de audio_alsa.c sont
   appelées, via son en-tête interne. */
#include "../linux/audio_alsa_interne.h"

#include <stdio.h>
#include <string.h>

static int echecs;

static void verifier_chemin(const char *repertoire, const char *nom,
			    const char *attendu)
{
	char chemin[256];
	int ok = alsa_chemin_dans_repertoire(chemin, sizeof(chemin), repertoire, nom);
	if (!ok) {
		fprintf(stderr, "ERREUR : chemin refusé pour « %s » + « %s »\n",
		        repertoire, nom);
		echecs++;
		return;
	}
	if (strcmp(chemin, attendu) != 0) {
		fprintf(stderr, "ERREUR : « %s » + « %s » donne « %s », attendu « %s »\n",
		        repertoire, nom, chemin, attendu);
		echecs++;
		return;
	}
	printf("OK chemin %s\n", chemin);
}

static void verifier_hw(const char *nom, const char *attendu)
{
	char chemin[64];
	int ok = alsa_construire_chemin_hw(nom, chemin, sizeof(chemin));
	if (!ok) {
		fprintf(stderr, "ERREUR : chemin hw refusé pour « %s »\n", nom);
		echecs++;
		return;
	}
	if (strcmp(chemin, attendu) != 0) {
		fprintf(stderr, "ERREUR : « %s » donne « %s », attendu « %s »\n",
		        nom, chemin, attendu);
		echecs++;
		return;
	}
	printf("OK périphérique %s -> %s\n", nom, chemin);
}

static void verifier_troncature(void)
{
	char petit[8];
	int ok = alsa_chemin_dans_repertoire(petit, sizeof(petit),
					     "/usr/lib", "libasound.so.2");
	if (ok) {
		fprintf(stderr, "ERREUR : troncature non signalée : « %s »\n", petit);
		echecs++;
	} else {
		printf("OK troncature répertoire signalée\n");
	}

	ok = alsa_construire_chemin_hw("hw:1,3", petit, sizeof(petit));
	if (ok) {
		fprintf(stderr, "ERREUR : troncature hw non signalée : « %s »\n", petit);
		echecs++;
	} else {
		printf("OK troncature périphérique signalée\n");
	}
}

int main(void)
{
	verifier_chemin("/usr/lib", "libasound.so.2", "/usr/lib/libasound.so.2");
	verifier_chemin("/usr/lib/", "libasound.so.2", "/usr/lib/libasound.so.2");
	verifier_chemin("/usr/lib///", "libasound.so", "/usr/lib/libasound.so");
	verifier_chemin("/", "libasound.so.2", "/libasound.so.2");
	verifier_chemin("", "libasound.so.2", "/libasound.so.2");

	verifier_hw("hw:0,0", "/dev/snd/pcmC0D0p");
	verifier_hw("hw:1,3", "/dev/snd/pcmC1D3p");
	verifier_hw("hw:12,7", "/dev/snd/pcmC12D7p");
	/* Format invalide ou indices négatifs : repli documenté sur la carte 0. */
	verifier_hw("hw:x,y", "/dev/snd/pcmC0D0p");
	verifier_hw("default", "/dev/snd/pcmC0D0p");
	verifier_hw("hw:-1,0", "/dev/snd/pcmC0D0p");

	verifier_troncature();

	if (echecs) {
		fprintf(stderr, "%d erreur(s)\n", echecs);
		return 1;
	}
	printf("Tous les chemins sont corrects.\n");
	return 0;
}
