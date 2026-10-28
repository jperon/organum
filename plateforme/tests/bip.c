#define _GNU_SOURCE
#include "../audio.h"

#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

static void erreur_ouverture(const char *periph)
{
	if (errno == EBUSY) {
		fprintf(stderr, "ERREUR : périphérique occupé (EBUSY)\n");
	} else {
		fprintf(stderr, "ERREUR ouverture audio (%s): %s\n",
		        periph ? periph : "default", strerror(errno));
	}
}

int main(int argc, char **argv)
{
	const char *periph = NULL;
	int verifier = 0;
	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--verifier") == 0) {
			verifier = 1;
		} else if (argv[i][0] != '-') {
			periph = argv[i];
		}
	}

	const char *nom_periph = periph ? periph : "default";

	int taux = 48000;
	int canaux = 2;
	int periode = 512;
	int nb_periodes = 4;

	if (verifier) {
		audio_t *audio = audio_ouvrir(periph, taux, canaux, periode, nb_periodes);
		if (!audio) {
			erreur_ouverture(nom_periph);
			return 1;
		}
		printf("Chemin pris : %s\n", audio_chemin(audio));
		printf("Périphérique : %s\n", nom_periph);
		printf("Taux négocié : %d Hz\n", taux);
		printf("Format négocié : %s\n", audio_format(audio));
		printf("Canaux négociés : %d\n", canaux);
		printf("Xruns : %d\n", audio_xruns(audio));
		audio_fermer(audio);
		return 0;
	}

	audio_t *audio = audio_ouvrir(periph, taux, canaux, periode, nb_periodes);
	if (!audio) {
		erreur_ouverture(nom_periph);
		return 1;
	}

	printf("Chemin pris : %s\n", audio_chemin(audio));
	printf("Périphérique : %s\n", nom_periph);
	printf("Taux négocié : %d Hz\n", taux);
	printf("Format négocié : %s\n", audio_format(audio));
	printf("Canaux négociés : %d\n", canaux);

	double freq = 440.0;
	double duree = 1.0;
	double amp = 0.2;
	int total_trames = (int)(taux * duree);
	int bloc = periode;
	float *buf = malloc((size_t)bloc * canaux * sizeof(float));
	if (!buf) {
		fprintf(stderr, "ERREUR allocation\n");
		audio_fermer(audio);
		return 1;
	}

	for (int t = 0; t < total_trames; t += bloc) {
		int n = bloc;
		if (t + n > total_trames)
			n = total_trames - t;
		for (int i = 0; i < n; i++) {
			/* fade court pour éviter les clics */
			double env = 1.0;
			int pos = t + i;
			int fade = taux / 200; /* 5 ms */
			if (pos < fade) env = (double)pos / (double)fade;
			if (pos > total_trames - fade) env = (double)(total_trames - pos) / (double)fade;
			if (env < 0.0) env = 0.0;
			double phase = 2.0 * M_PI * freq * (double)pos / (double)taux;
			float s = (float)(amp * env * sin(phase));
			for (int c = 0; c < canaux; c++) {
				buf[i * canaux + c] = s;
			}
		}
		int w = audio_ecrire(audio, buf, n);
		if (w < 0) {
			if (errno == EPIPE) {
				fprintf(stderr, "ERREUR écriture: EPIPE (xrun)\n");
			} else {
				fprintf(stderr, "ERREUR écriture: %s\n", strerror(errno));
			}
			free(buf);
			audio_fermer(audio);
			return 1;
		}
	}

	printf("Xruns cumulés : %d\n", audio_xruns(audio));
	free(buf);
	audio_fermer(audio);
	return 0;
}
