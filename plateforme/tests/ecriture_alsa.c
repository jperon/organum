/* Vérifie la boucle d'écriture du chemin libasound sans PCM réel : un faux
   snd_pcm_writei renvoie tour à tour 0, -EAGAIN, un compte partiel et
   -EPIPE. Aucune trame ne doit être perdue, les xruns comptés et la
   récupération appelée. Vérifie aussi l'alignement de PIPEWIRE_LATENCY.
   L'injection est réservée aux tests via audio_alsa_interne.h. */
#include "../audio.h"
#include "../linux/audio_alsa_interne.h"

#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CANAUX 2
#define TRAMES 512

static int echecs;

static short recu[TRAMES * CANAUX];
static size_t recues;
static int etape;
static int nb_attentes;
static int nb_recuperations;
static int mode; /* 0 = nominal, 1 = toujours 0, 2 = toujours EPIPE */

static long faux_writei(void *pcm, const void *tampon, unsigned long trames)
{
	(void)pcm;
	size_t echantillons = (size_t)trames * CANAUX;
	size_t octets = echantillons * sizeof(short);

	if (mode == 1)
		return 0;
	if (mode == 2)
		return -EPIPE;

	switch (etape++) {
	case 0:
		return 0;
	case 1:
		return -EAGAIN;
	case 2: {
		size_t partiel = (size_t)trames / 3 + 1;
		if (partiel > trames)
			partiel = trames;
		memcpy(recu + recues * CANAUX, tampon, partiel * CANAUX * sizeof(short));
		recues += partiel;
		return (long)partiel;
	}
	case 3:
		return -EPIPE;
	default:
		if (recues + trames > TRAMES) {
			fprintf(stderr, "ERREUR : écriture au-delà du tampon de test\n");
			return -EIO;
		}
		memcpy(recu + recues * CANAUX, tampon, octets);
		recues += trames;
		return (long)trames;
	}
}

static int faux_wait(void *pcm, int delai_ms)
{
	(void)pcm;
	(void)delai_ms;
	nb_attentes++;
	return 0;
}

static int faux_recover(void *pcm, int err, int silence)
{
	(void)pcm;
	(void)err;
	(void)silence;
	nb_recuperations++;
	return mode == 2 ? -EIO : 0;
}

static void reinitialiser(void)
{
	memset(recu, 0, sizeof(recu));
	recues = 0;
	etape = 0;
	nb_attentes = 0;
	nb_recuperations = 0;
	mode = 0;
}

static void installer(void)
{
	static const struct alsa_libasound faux = {
		.pcm_writei = faux_writei,
		.pcm_wait = faux_wait,
		.pcm_recover = faux_recover,
	};
	alsa_audio_injecter_libasound(&faux);
}

static void remplir(float *entree)
{
	for (int i = 0; i < TRAMES * CANAUX; i++)
		entree[i] = (float)((i % 9) - 4) / 8.0f;
}

static short attendu(float v)
{
	if (v > 1.0f) v = 1.0f;
	if (v < -1.0f) v = -1.0f;
	long s = (long)lrintf(v * 32767.0f);
	if (s > 32767) s = 32767;
	if (s < -32768) s = -32768;
	return (short)s;
}

static void verifier_nominal(void)
{
	reinitialiser();
	float entree[TRAMES * CANAUX];
	remplir(entree);

	audio_t *audio = alsa_audio_creer_pour_test(CANAUX, TRAMES, 0);
	if (!audio) {
		fprintf(stderr, "ERREUR : création du contexte de test impossible\n");
		echecs++;
		return;
	}

	int r = audio_ecrire(audio, entree, TRAMES);
	if (r != TRAMES) {
		fprintf(stderr, "ERREUR : écriture nominale rend %d, attendu %d\n", r, TRAMES);
		echecs++;
	}
	if (recues != TRAMES) {
		fprintf(stderr, "ERREUR : %zu trames reçues, attendu %d (trames perdues)\n",
		        recues, TRAMES);
		echecs++;
	}
	for (int i = 0; i < TRAMES * CANAUX; i++) {
		short a = attendu(entree[i]);
		if (recu[i] != a) {
			fprintf(stderr, "ERREUR : échantillon %d = %d, attendu %d\n",
			        i, recu[i], a);
			echecs++;
			break;
		}
	}
	if (audio_xruns(audio) != 1) {
		fprintf(stderr, "ERREUR : xruns=%d, attendu 1\n", audio_xruns(audio));
		echecs++;
	}
	if (nb_recuperations != 1) {
		fprintf(stderr, "ERREUR : récupération appelée %d fois, attendu 1\n",
		        nb_recuperations);
		echecs++;
	}
	if (nb_attentes < 2) {
		fprintf(stderr, "ERREUR : attentes=%d, attendu au moins 2 (0 et EAGAIN)\n",
		        nb_attentes);
		echecs++;
	}

	audio_fermer(audio);
	printf("OK boucle d'écriture : 0/EAGAIN/partiel/EPIPE, %zu trames intactes, "
	       "%d attente(s), %d récupération(s)\n",
	       recues, nb_attentes, nb_recuperations);
}

static void verifier_echec_essais(void)
{
	reinitialiser();
	mode = 1;
	float entree[32 * CANAUX] = { 0 };

	audio_t *audio = alsa_audio_creer_pour_test(CANAUX, 32, 0);
	if (!audio) {
		fprintf(stderr, "ERREUR : création du contexte de test impossible\n");
		echecs++;
		return;
	}
	int r = audio_ecrire(audio, entree, 32);
	if (r != -EAGAIN) {
		fprintf(stderr, "ERREUR : écriture bloquée rend %d, attendu %d\n",
		        r, -EAGAIN);
		echecs++;
	}
	if (nb_attentes == 0 || nb_attentes > 1001) {
		fprintf(stderr, "ERREUR : nombre d'attentes anormal : %d\n", nb_attentes);
		echecs++;
	}
	if (audio_xruns(audio) != 0) {
		fprintf(stderr, "ERREUR : xruns=%d après échec sans EPIPE\n",
		        audio_xruns(audio));
		echecs++;
	}
	audio_fermer(audio);
	printf("OK échec borné après %d attente(s) : rend -EAGAIN\n", nb_attentes);
}

static void verifier_echec_recuperation(void)
{
	reinitialiser();
	mode = 2;
	float entree[32 * CANAUX] = { 0 };

	audio_t *audio = alsa_audio_creer_pour_test(CANAUX, 32, 0);
	if (!audio) {
		fprintf(stderr, "ERREUR : création du contexte de test impossible\n");
		echecs++;
		return;
	}
	int r = audio_ecrire(audio, entree, 32);
	if (r != -EIO) {
		fprintf(stderr, "ERREUR : échec de récupération rend %d, attendu %d\n",
		        r, -EIO);
		echecs++;
	}
	if (audio_xruns(audio) != 1 || nb_recuperations != 1) {
		fprintf(stderr, "ERREUR : xruns=%d récupérations=%d, attendu 1/1\n",
		        audio_xruns(audio), nb_recuperations);
		echecs++;
	}
	audio_fermer(audio);
	printf("OK échec de récupération propagé (-EIO), xrun compté\n");
}

static void verifier_latence(void)
{
	unsetenv("PIPEWIRE_LATENCY");
	if (!alsa_configurer_latence_pipewire("default", 512, 48000)) {
		fprintf(stderr, "ERREUR : PIPEWIRE_LATENCY non définie pour default\n");
		echecs++;
	} else {
		const char *v = getenv("PIPEWIRE_LATENCY");
		if (!v || strcmp(v, "512/48000") != 0) {
			fprintf(stderr, "ERREUR : PIPEWIRE_LATENCY=« %s », attendu 512/48000\n",
			        v ? v : "(non définie)");
			echecs++;
		} else {
			printf("OK PIPEWIRE_LATENCY=512/48000 pour default\n");
		}
	}

	if (alsa_configurer_latence_pipewire("default", 1024, 48000)) {
		fprintf(stderr, "ERREUR : valeur utilisateur PIPEWIRE_LATENCY écrasée\n");
		echecs++;
	}
	const char *v = getenv("PIPEWIRE_LATENCY");
	if (!v || strcmp(v, "512/48000") != 0) {
		fprintf(stderr, "ERREUR : valeur existante modifiée : « %s »\n",
		        v ? v : "(non définie)");
		echecs++;
	} else {
		printf("OK PIPEWIRE_LATENCY existante conservée\n");
	}

	setenv("PIPEWIRE_LATENCY", "1024/48000", 1);
	if (alsa_configurer_latence_pipewire("default", 256, 48000)) {
		fprintf(stderr, "ERREUR : PIPEWIRE_LATENCY utilisateur remplacée\n");
		echecs++;
	}
	v = getenv("PIPEWIRE_LATENCY");
	if (!v || strcmp(v, "1024/48000") != 0) {
		fprintf(stderr, "ERREUR : PIPEWIRE_LATENCY utilisateur altérée : « %s »\n",
		        v ? v : "(non définie)");
		echecs++;
	}

	unsetenv("PIPEWIRE_LATENCY");
	if (alsa_configurer_latence_pipewire("hw:0,0", 512, 48000)) {
		fprintf(stderr, "ERREUR : PIPEWIRE_LATENCY définie pour hw:\n");
		echecs++;
	}
	if (getenv("PIPEWIRE_LATENCY")) {
		fprintf(stderr, "ERREUR : PIPEWIRE_LATENCY présente après hw:\n");
		echecs++;
	} else {
		printf("OK PIPEWIRE_LATENCY absente pour hw:\n");
	}
}

int main(void)
{
	installer();

	verifier_nominal();
	verifier_echec_essais();
	verifier_echec_recuperation();
	verifier_latence();

	alsa_audio_injecter_libasound(NULL);

	if (echecs) {
		fprintf(stderr, "%d erreur(s)\n", echecs);
		return 1;
	}
	printf("Boucle d'écriture ALSA et latence PipeWire : tous les cas sont corrects.\n");
	return 0;
}
