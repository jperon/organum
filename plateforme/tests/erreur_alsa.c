#define _GNU_SOURCE
/* Vérifie le diagnostic de chargement de libasound.
   Le cas d'échec est toujours exercé : ORGANUM_LIBASOUND pointe vers un
   chemin absent et ORGANUM_LIBASOUND_STRICT interdit le repli sur
   libasound.so.2/system, même si une libasound est installée.
   Ensuite, le chargement effectif est vérifié si un vrai libasound est
   disponible : chemin passé en argument (ou ORGANUM_TEST_LIBASOUND), sinon
   libasound système. L'ouverture utilise un nom de PCM volontairement
   absent : seule l'étape de chargement est ainsi testée, sans toucher au
   serveur audio ni au matériel.

   Chaque tentative tourne dans un processus fils car libasound_load() ne
   mémorise qu'une seule tentative par processus. */
#include "../audio.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#define PERIPHERIQUE_TEST "organum-test-peripherique-absent"
#define CHEMIN_ABSENT "/organum/chemin/volontairement/absent/libasound.so.2"

static int attendre(pid_t pid)
{
	int statut;
	pid_t r;
	while ((r = waitpid(pid, &statut, 0)) < 0 && errno == EINTR)
		;
	if (r != pid) {
		perror("waitpid");
		return 1;
	}
	if (!WIFEXITED(statut)) {
		fprintf(stderr, "ERREUR : processus fils interrompu\n");
		return 1;
	}
	return WEXITSTATUS(statut);
}

/* libasound s'est chargée, mais snd_pcm_open() a refusé le périphérique
   factice : c'est exactement ce qu'on attend de l'étape de succès. */
static int chargement_reussi(const char *erreur)
{
	return erreur && (strncmp(erreur, "snd_pcm_open(", 13) == 0 ||
	                  strncmp(erreur, "snd_pcm_set_params(", 19) == 0);
}

static int essayer_echec(void)
{
	pid_t pid = fork();
	if (pid < 0) {
		perror("fork");
		return 1;
	}
	if (pid == 0) {
		setenv("ORGANUM_LIBASOUND", CHEMIN_ABSENT, 1);
		setenv("ORGANUM_LIBASOUND_STRICT", "1", 1);

		audio_t *audio = audio_ouvrir(PERIPHERIQUE_TEST, 48000, 2, 512, 4);
		if (audio) {
			audio_fermer(audio);
			fprintf(stderr, "ERREUR : ouverture acceptée malgré un chemin absent\n");
			_exit(1);
		}

		const char *erreur = audio_derniere_erreur();
		if (!erreur || !erreur[0]) {
			fprintf(stderr, "ERREUR : aucune erreur mémorisée\n");
			_exit(2);
		}
		if (!strstr(erreur, CHEMIN_ABSENT)) {
			fprintf(stderr, "ERREUR : chemin absent du diagnostic : %s\n", erreur);
			_exit(3);
		}
		if (!strstr(erreur, "ORGANUM_LIBASOUND_STRICT")) {
			fprintf(stderr, "ERREUR : repli non désactivé : %s\n", erreur);
			_exit(4);
		}

		printf("OK échec attendu : %s\n", erreur);
		fflush(stdout);
		_exit(0);
	}
	return attendre(pid);
}

static int essayer_succes(const char *reel)
{
	pid_t pid = fork();
	if (pid < 0) {
		perror("fork");
		return 1;
	}
	if (pid == 0) {
		if (reel && reel[0]) {
			setenv("ORGANUM_LIBASOUND", reel, 1);
			setenv("ORGANUM_LIBASOUND_STRICT", "1", 1);
		} else {
			unsetenv("ORGANUM_LIBASOUND");
			unsetenv("ORGANUM_LIBASOUND_STRICT");
		}

		audio_t *audio = audio_ouvrir(PERIPHERIQUE_TEST, 48000, 2, 512, 4);
		if (audio) {
			audio_fermer(audio);
			printf("OK chargement (%s)\n", reel && reel[0] ? reel : "libasound système");
			fflush(stdout);
			_exit(0);
		}

		const char *erreur = audio_derniere_erreur();
		if (chargement_reussi(erreur)) {
			printf("OK chargement (%s) ; ouverture refusée comme prévu : %s\n",
			       reel && reel[0] ? reel : "libasound système", erreur);
			fflush(stdout);
			_exit(0);
		}

		if (!reel || !reel[0]) {
			printf("IGNORÉ : aucune libasound disponible pour le cas de succès");
			if (erreur && erreur[0])
				printf(" (%s)", erreur);
			printf("\n");
			fflush(stdout);
			_exit(0);
		}

		fprintf(stderr, "ERREUR : ORGANUM_LIBASOUND=%s n'a pas chargé libasound : %s\n",
		        reel, (erreur && erreur[0]) ? erreur : "erreur inconnue");
		_exit(1);
	}
	return attendre(pid);
}

int main(int argc, char **argv)
{
	int code = essayer_echec();
	if (code)
		return code;

	const char *reel = NULL;
	if (argc > 1 && argv[1][0])
		reel = argv[1];
	else
		reel = getenv("ORGANUM_TEST_LIBASOUND");

	return essayer_succes(reel);
}
