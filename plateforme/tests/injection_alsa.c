/* Vérifie les échecs du chemin ioctl sans matériel : open occupé (EBUSY,
   EAGAIN), échec de F_GETFL et de F_SETFL après HW_PARAMS, échec de
   HW_PARAMS, et succès simulé. Les appels système du chemin ioctl sont
   remplacés par des fonctions de test via l'en-tête interne de
   audio_alsa.c. */
#include "../backends.h"
#include <time.h>
#include "../linux/asound_min.h"
#include "../linux/audio_alsa_interne.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>

static int echecs;

struct etat {
	int echec_open;
	int errno_open;
	int echec_fcntl_get;
	int echec_fcntl_set;
	int echec_hw_params;
	int fd;
	int nb_close;
	int nb_open;
	int nb_ioctl;
	int nb_fcntl_set;
};

static struct etat etat;

static int test_open(const char *chemin, int drapeaux, ...)
{
	(void)chemin;
	(void)drapeaux;
	etat.nb_open++;
	if (etat.echec_open) {
		errno = etat.errno_open;
		return -1;
	}
	return etat.fd;
}

static int test_fcntl(int fd, int commande, ...)
{
	(void)fd;
	if (commande == F_GETFL) {
		if (etat.echec_fcntl_get) {
			errno = EIO;
			return -1;
		}
		return O_WRONLY | O_NONBLOCK;
	}
	if (commande == F_SETFL) {
		etat.nb_fcntl_set++;
		if (etat.echec_fcntl_set) {
			errno = EIO;
			return -1;
		}
	}
	return 0;
}

static int test_close(int fd)
{
	(void)fd;
	etat.nb_close++;
	return 0;
}

static int test_ioctl(int fd, unsigned long requete, ...)
{
	(void)fd;
	etat.nb_ioctl++;
	if (requete == SNDRV_PCM_IOCTL_HW_PARAMS && etat.echec_hw_params) {
		errno = EINVAL;
		return -1;
	}
	return 0;
}

static void reinitialiser(void)
{
	memset(&etat, 0, sizeof(etat));
	etat.fd = 42;
}

static void installer(void)
{
	struct alsa_systeme systeme = {
		.sys_open = test_open,
		.sys_fcntl = test_fcntl,
		.sys_close = test_close,
		.sys_ioctl = test_ioctl,
	};
	alsa_audio_injecter_systeme(&systeme);
}

static void verifier_open_occupe(int code)
{
	reinitialiser();
	etat.echec_open = 1;
	etat.errno_open = code;

	audio_t *audio = alsa_audio_ouvrir("hw:0,0", 48000, 2, 512, 4);
	if (audio) {
		fprintf(stderr, "ERREUR : ouverture acceptée avec open() en échec\n");
		echecs++;
		alsa_audio_fermer(audio);
		return;
	}
	if (errno != code) {
		fprintf(stderr, "ERREUR : errno=%d, attendu %d\n", errno, code);
		echecs++;
		return;
	}
	const char *erreur = alsa_audio_derniere_erreur();
	if (!erreur || !strstr(erreur, "occupé") || !strstr(erreur, "default")) {
		fprintf(stderr, "ERREUR : message d'occupation incomplet : %s\n",
		        erreur ? erreur : "(aucun)");
		echecs++;
		return;
	}
	if (etat.nb_close != 0) {
		fprintf(stderr, "ERREUR : close() appelé sans descripteur ouvert\n");
		echecs++;
		return;
	}
	printf("OK open errno=%d -> %s\n", code, erreur);
}

/* mode_get : l'échec porte sur F_GETFL ; sinon sur F_SETFL, qui doit
   réellement être appelé après un F_GETFL réussi. */
static void verifier_echec_fcntl(int mode_get)
{
	reinitialiser();
	if (mode_get)
		etat.echec_fcntl_get = 1;
	else
		etat.echec_fcntl_set = 1;

	audio_t *audio = alsa_audio_ouvrir("hw:0,0", 48000, 2, 512, 4);
	if (audio) {
		fprintf(stderr, "ERREUR : ouverture acceptée avec fcntl() en échec\n");
		echecs++;
		alsa_audio_fermer(audio);
		return;
	}
	int err = errno;
	const char *erreur = alsa_audio_derniere_erreur();
	if (!erreur || !strstr(erreur, "fcntl(")) {
		fprintf(stderr, "ERREUR : message fcntl absent : %s\n",
		        erreur ? erreur : "(aucun)");
		echecs++;
		return;
	}
	if (err != EIO) {
		fprintf(stderr, "ERREUR : errno=%d après fcntl, attendu %d\n", err, EIO);
		echecs++;
		return;
	}
	if (etat.nb_close != 1) {
		fprintf(stderr, "ERREUR : descripteur non fermé après fcntl (close=%d)\n",
		        etat.nb_close);
		echecs++;
		return;
	}
	if (!mode_get && etat.nb_fcntl_set != 1) {
		fprintf(stderr, "ERREUR : F_SETFL non exercé (appels=%d)\n",
		        etat.nb_fcntl_set);
		echecs++;
		return;
	}
	printf("OK fcntl %s en échec, errno conservé, descripteur fermé : %s\n",
	       mode_get ? "F_GETFL" : "F_SETFL", erreur);
}

static void verifier_echec_hw_params(void)
{
	reinitialiser();
	etat.echec_hw_params = 1;

	audio_t *audio = alsa_audio_ouvrir("hw:0,0", 48000, 2, 512, 4);
	if (audio) {
		fprintf(stderr, "ERREUR : ouverture acceptée avec HW_PARAMS() en échec\n");
		echecs++;
		alsa_audio_fermer(audio);
		return;
	}
	int err = errno;
	const char *erreur = alsa_audio_derniere_erreur();
	if (!erreur || !strstr(erreur, "HW_PARAMS(")) {
		fprintf(stderr, "ERREUR : message HW_PARAMS absent : %s\n",
		        erreur ? erreur : "(aucun)");
		echecs++;
		return;
	}
	if (err != EINVAL) {
		fprintf(stderr, "ERREUR : errno=%d après HW_PARAMS, attendu %d\n",
		        err, EINVAL);
		echecs++;
		return;
	}
	if (etat.nb_close != 1) {
		fprintf(stderr, "ERREUR : descripteur non fermé après HW_PARAMS (close=%d)\n",
		        etat.nb_close);
		echecs++;
		return;
	}
	printf("OK HW_PARAMS en échec, errno conservé, descripteur fermé : %s\n",
	       erreur);
}

static void verifier_succes(void)
{
	reinitialiser();

	audio_t *audio = alsa_audio_ouvrir("hw:0,0", 48000, 2, 512, 4);
	if (!audio) {
		const char *erreur = alsa_audio_derniere_erreur();
		fprintf(stderr, "ERREUR : ouverture simulée refusée : %s\n",
		        erreur ? erreur : "(aucun message)");
		echecs++;
		return;
	}
	if (alsa_audio_derniere_erreur()) {
		fprintf(stderr, "ERREUR : erreur mémorisée malgré un succès : %s\n",
		        alsa_audio_derniere_erreur());
		echecs++;
	}
	if (etat.nb_ioctl == 0) {
		fprintf(stderr, "ERREUR : aucun ioctl simulé\n");
		echecs++;
	}
	alsa_audio_fermer(audio);
	if (etat.nb_close != 1) {
		fprintf(stderr, "ERREUR : descripteur non fermé après succès (close=%d)\n",
		        etat.nb_close);
		echecs++;
		return;
	}
	printf("OK succès simulé (%d ioctl, descripteur fermé)\n", etat.nb_ioctl);
}

int main(void)
{
	installer();

	verifier_open_occupe(EBUSY);
	verifier_open_occupe(EAGAIN);
	verifier_echec_fcntl(1);
	verifier_echec_fcntl(0);
	verifier_echec_hw_params();
	verifier_succes();

	alsa_audio_injecter_systeme(NULL);

	if (echecs) {
		fprintf(stderr, "%d erreur(s)\n", echecs);
		return 1;
	}
	printf("Injection ioctl : tous les cas sont corrects.\n");
	return 0;
}
