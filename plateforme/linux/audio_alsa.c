#define _GNU_SOURCE
#include "../backends.h"

#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <poll.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#if defined(__COSMOPOLITAN__)
#include <cosmo.h>
#endif

#include <dlfcn.h>

#include "asound_min.h"
#include "audio_alsa_interne.h"

#define SND_PCM_STREAM_PLAYBACK 0
#define SND_PCM_ACCESS_RW_INTERLEAVED 3
#define SND_PCM_FORMAT_S16_LE 2
#define SND_PCM_FORMAT_S32_LE 10
#define SND_PCM_FORMAT_FLOAT_LE 14

struct audio {
	int chemin; /* 0 = ioctl, 1 = libasound */
	int xruns;
	int canaux;
	int taux;
	int periode;
	int nb_periodes;
	int fmt; /* 0 = S16_LE, 1 = S32_LE, 2 = FLOAT_LE */
	int fd;
	void *pcm;
	void *tampon; /* conversion S16/S32, allouée une fois */
	size_t tampon_capacite; /* en échantillons, pas en trames */
};

/* ---------- libasound dynamique ---------- */

typedef struct _snd_pcm snd_pcm_t;
typedef long snd_pcm_sframes_t;
typedef unsigned long snd_pcm_uframes_t;

typedef int (*snd_pcm_open_t)(snd_pcm_t **, const char *, int, int);
typedef int (*snd_pcm_set_params_t)(snd_pcm_t *, int, int, unsigned int, unsigned int, int, unsigned int);
typedef snd_pcm_sframes_t (*snd_pcm_writei_t)(snd_pcm_t *, const void *, snd_pcm_uframes_t);
typedef int (*snd_pcm_recover_t)(snd_pcm_t *, int, int);
typedef int (*snd_pcm_close_t)(snd_pcm_t *);
typedef const char *(*snd_strerror_t)(int);
typedef int (*snd_pcm_prepare_t)(snd_pcm_t *);
typedef int (*snd_pcm_wait_t)(snd_pcm_t *, int);

static snd_pcm_open_t p_snd_pcm_open = NULL;
static snd_pcm_set_params_t p_snd_pcm_set_params = NULL;
static snd_pcm_writei_t p_snd_pcm_writei = NULL;
static snd_pcm_recover_t p_snd_pcm_recover = NULL;
static snd_pcm_close_t p_snd_pcm_close = NULL;
static snd_strerror_t p_snd_strerror = NULL;
static snd_pcm_prepare_t p_snd_pcm_prepare = NULL;
static snd_pcm_wait_t p_snd_pcm_wait = NULL;

static int libasound_tried = 0;
static int libasound_ok = 0;
static void *libasound_handle = NULL;

/* Diagnostic séparé en deux tampons : le chargement de libasound dure toute
   la vie du processus, l'ouverture du PCM est propre à chaque tentative.
   alsa_audio_derniere_erreur() renvoie l'erreur d'ouverture si elle est
   renseignée, sinon celle de chargement : un échec d'ouverture est plus
   proche de l'appelant qu'un échec de chargement, et ne doit jamais être
   masqué par un message de chargement périmé. */
static char erreur_chargement[1024];
static char erreur_ouverture[1024];

static void erreur_effacer(char *tampon)
{
	tampon[0] = '\0';
}

static void erreur_ajouter(char *tampon, size_t taille, const char *format, ...)
{
	size_t deja = strlen(tampon);
	if (deja) {
		if (deja + 3 >= taille)
			return;
		memcpy(tampon + deja, " ; ", 3);
		deja += 3;
	}
	va_list ap;
	va_start(ap, format);
	vsnprintf(tampon + deja, taille - deja, format, ap);
	va_end(ap);
}

/* Mémorise l'échec de chargement pour le diagnostic. Le message reste dans
   erreur_chargement : libasound_tried interdit toute nouvelle tentative, donc
   aucun chemin ne l'efface après un échec. */
static int chargement_echouer(void)
{
	libasound_ok = 0;
	return 0;
}

static void *essayer_dlopen(const char *chemin)
{
	void *handle = cosmo_dlopen(chemin, RTLD_NOW);
	if (!handle) {
		const char *detail = cosmo_dlerror();
		erreur_ajouter(erreur_chargement, sizeof(erreur_chargement),
		               "%s : %s", chemin,
		               (detail && detail[0]) ? detail : "échec de cosmo_dlopen");
	}
	return handle;
}

static void *charger_symbole(void *handle, const char *nom)
{
	/* cosmo_dltramp(NULL) renvoie un trampoline non nul : vérifier le
	   symbole avant de le transformer. */
	void *symbole = cosmo_dlsym(handle, nom);
	if (!symbole)
		return NULL;
	return cosmo_dltramp(symbole);
}

/* Construit « répertoire/nom » sans slash final redoublé. Renvoie 0 si le
   chemin ne tient pas dans le tampon (troncature). Un répertoire racine
   (« / ») est ramené à un préfixe vide, ce qui donne « /libasound.so.2 ». */
int alsa_chemin_dans_repertoire(char *chemin, size_t taille,
				const char *repertoire, const char *nom)
{
	size_t longueur = strlen(repertoire);
	while (longueur > 1 && repertoire[longueur - 1] == '/')
		longueur--;
	if (longueur == 1 && repertoire[0] == '/')
		longueur = 0;

	int n = snprintf(chemin, taille, "%.*s/%s", (int)longueur, repertoire, nom);
	return n >= 0 && (size_t)n < taille;
}

int alsa_construire_chemin_hw(const char *nom, char *chemin, size_t taille)
{
	int carte = -1, dev = -1;
	int n;
	if (sscanf(nom, "hw:%d,%d", &carte, &dev) == 2 && carte >= 0 && dev >= 0)
		n = snprintf(chemin, taille, "/dev/snd/pcmC%dD%dp", carte, dev);
	else
		n = snprintf(chemin, taille, "/dev/snd/pcmC0D0p");
	return n >= 0 && (size_t)n < taille;
}

/* Appels système du chemin ioctl : directs par défaut, remplaçables par les
   tests. Le chemin libasound n'y touche pas. */
static struct alsa_systeme systeme = { open, fcntl, close, ioctl };

void alsa_audio_injecter_systeme(const struct alsa_systeme *s)
{
	if (s) {
		systeme = *s;
	} else {
		systeme.sys_open = open;
		systeme.sys_fcntl = fcntl;
		systeme.sys_close = close;
		systeme.sys_ioctl = ioctl;
	}
}

/* Fonctions libasound remplaçables par les tests de la boucle d'écriture.
   En production, l'injection reste NULL et les symboles chargés servent. */
static const struct alsa_libasound *libasound_injecte = NULL;

void alsa_audio_injecter_libasound(const struct alsa_libasound *s)
{
	libasound_injecte = s;
}

static snd_pcm_sframes_t pcm_ecrire(snd_pcm_t *pcm, const void *tampon,
				    snd_pcm_uframes_t trames)
{
	if (libasound_injecte && libasound_injecte->pcm_writei)
		return libasound_injecte->pcm_writei(pcm, tampon, trames);
	if (!p_snd_pcm_writei) {
		errno = ENODEV;
		return -ENODEV;
	}
	return p_snd_pcm_writei(pcm, tampon, trames);
}

static int pcm_attendre(snd_pcm_t *pcm, int delai_ms)
{
	if (libasound_injecte && libasound_injecte->pcm_wait)
		return libasound_injecte->pcm_wait(pcm, delai_ms);
	if (p_snd_pcm_wait)
		return p_snd_pcm_wait(pcm, delai_ms);
	/* Repli sans snd_pcm_wait : petite attente bornée, jamais bloquante
	   indéfiniment. */
	struct timespec pause = { 0, 1000000L };
	nanosleep(&pause, NULL);
	return 0;
}

static int pcm_recuperer(snd_pcm_t *pcm, int err)
{
	if (libasound_injecte && libasound_injecte->pcm_recover)
		return libasound_injecte->pcm_recover(pcm, err, 1);
	if (p_snd_pcm_recover)
		return p_snd_pcm_recover(pcm, err, 1);
	return -ENODEV;
}

static int libasound_load(void)
{
	if (libasound_tried)
		return libasound_ok;
	libasound_tried = 1;
	erreur_effacer(erreur_chargement);

	/* ORGANUM_LIBASOUND : fichier .so ou répertoire (NixOS, Guix, …).
	   Essayé avant les noms génériques, que le chargeur peut ne pas savoir
	   résoudre sans cache ld.so. 4096 octets : taille usuelle de PATH_MAX
	   sous Linux, largement suffisante pour un chemin du magasin Nix. */
	const char *force = getenv("ORGANUM_LIBASOUND");
	int force_utilisee = 0;
	if (force && force[0]) {
		force_utilisee = 1;
		struct stat st;
		if (stat(force, &st) == 0 && S_ISDIR(st.st_mode)) {
			char chemin[4096];
			if (!alsa_chemin_dans_repertoire(chemin, sizeof(chemin), force, "libasound.so.2")) {
				erreur_ajouter(erreur_chargement, sizeof(erreur_chargement),
				               "ORGANUM_LIBASOUND trop long : %s", force);
				return chargement_echouer();
			}
			libasound_handle = essayer_dlopen(chemin);
			if (!libasound_handle) {
				if (!alsa_chemin_dans_repertoire(chemin, sizeof(chemin), force, "libasound.so")) {
					erreur_ajouter(erreur_chargement, sizeof(erreur_chargement),
					               "ORGANUM_LIBASOUND trop long : %s", force);
					return chargement_echouer();
				}
				libasound_handle = essayer_dlopen(chemin);
			}
		} else {
			libasound_handle = essayer_dlopen(force);
		}
	}

	/* ORGANUM_LIBASOUND_STRICT=1 (réservé aux tests) : ne jamais se replier
	   sur les noms génériques quand un chemin explicite a échoué. Cela rend
	   le diagnostic déterministe même sur une machine où libasound est
	   installée ailleurs. */
	const char *strict_env = getenv("ORGANUM_LIBASOUND_STRICT");
	int strict = strict_env && strcmp(strict_env, "1") == 0;

	if (!libasound_handle && !(strict && force_utilisee)) {
		libasound_handle = essayer_dlopen("libasound.so.2");
	}
	if (!libasound_handle && !(strict && force_utilisee)) {
		libasound_handle = essayer_dlopen("libasound.so");
	}
	if (!libasound_handle) {
		if (strict && force_utilisee)
			erreur_ajouter(erreur_chargement, sizeof(erreur_chargement),
			               "repli sur libasound.so.2 désactivé "
			               "(ORGANUM_LIBASOUND_STRICT)");
		else
			erreur_ajouter(erreur_chargement, sizeof(erreur_chargement),
			               "définissez ORGANUM_LIBASOUND (fichier .so ou répertoire) "
			               "si libasound n'est pas dans un chemin standard");
		return chargement_echouer();
	}

	const char *manquant = NULL;
	p_snd_pcm_open = (snd_pcm_open_t)charger_symbole(libasound_handle, "snd_pcm_open");
	if (!p_snd_pcm_open)
		manquant = "snd_pcm_open";
	p_snd_pcm_set_params = (snd_pcm_set_params_t)charger_symbole(libasound_handle, "snd_pcm_set_params");
	if (!p_snd_pcm_set_params)
		manquant = manquant ? manquant : "snd_pcm_set_params";
	p_snd_pcm_writei = (snd_pcm_writei_t)charger_symbole(libasound_handle, "snd_pcm_writei");
	if (!p_snd_pcm_writei)
		manquant = manquant ? manquant : "snd_pcm_writei";
	p_snd_pcm_recover = (snd_pcm_recover_t)charger_symbole(libasound_handle, "snd_pcm_recover");
	if (!p_snd_pcm_recover)
		manquant = manquant ? manquant : "snd_pcm_recover";
	p_snd_pcm_close = (snd_pcm_close_t)charger_symbole(libasound_handle, "snd_pcm_close");
	if (!p_snd_pcm_close)
		manquant = manquant ? manquant : "snd_pcm_close";
	p_snd_strerror = (snd_strerror_t)charger_symbole(libasound_handle, "snd_strerror");
	if (!p_snd_strerror)
		manquant = manquant ? manquant : "snd_strerror";
	p_snd_pcm_prepare = (snd_pcm_prepare_t)charger_symbole(libasound_handle, "snd_pcm_prepare");
	if (!p_snd_pcm_prepare)
		manquant = manquant ? manquant : "snd_pcm_prepare";
	/* snd_pcm_wait est facultatif : sans lui, la boucle d'écriture se
	   replie sur une attente bornée de 1 ms. */
	p_snd_pcm_wait = (snd_pcm_wait_t)charger_symbole(libasound_handle, "snd_pcm_wait");

	if (manquant) {
		erreur_ajouter(erreur_chargement, sizeof(erreur_chargement),
		               "symbole absent dans libasound : %s", manquant);
		/* Aucun pointeur ne doit survivre à la fermeture de la bibliothèque. */
		p_snd_pcm_open = NULL;
		p_snd_pcm_set_params = NULL;
		p_snd_pcm_writei = NULL;
		p_snd_pcm_recover = NULL;
		p_snd_pcm_close = NULL;
		p_snd_strerror = NULL;
		p_snd_pcm_prepare = NULL;
		p_snd_pcm_wait = NULL;
		cosmo_dlclose(libasound_handle);
		libasound_handle = NULL;
		return chargement_echouer();
	}
	/* Les tentatives ratées avant un chargement réussi ne sont pas une erreur. */
	erreur_effacer(erreur_chargement);
	libasound_ok = 1;
	return 1;
}

const char *alsa_audio_derniere_erreur(void)
{
	if (erreur_ouverture[0])
		return erreur_ouverture;
	if (erreur_chargement[0])
		return erreur_chargement;
	return NULL;
}

/* ---------- helpers ioctl ---------- */

static int audio_set_mask(struct snd_pcm_hw_params *params, snd_pcm_hw_param_t var, unsigned int val)
{
	if (var < SNDRV_PCM_HW_PARAM_FIRST_MASK || var > SNDRV_PCM_HW_PARAM_LAST_MASK)
		return -EINVAL;
	struct snd_mask *mask = &params->masks[var - SNDRV_PCM_HW_PARAM_FIRST_MASK];
	int idx = val / 32;
	int bit = val % 32;
	if (idx >= (int)((SNDRV_MASK_MAX + 31) / 32))
		return -EINVAL;
	mask->bits[idx] = (1u << bit);
	return 0;
}

static int audio_set_interval(struct snd_pcm_hw_params *params, snd_pcm_hw_param_t var, unsigned int minv, unsigned int maxv)
{
	if (var < SNDRV_PCM_HW_PARAM_FIRST_INTERVAL || var > SNDRV_PCM_HW_PARAM_LAST_INTERVAL)
		return -EINVAL;
	struct snd_interval *i = &params->intervals[var - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL];
	i->min = minv;
	i->max = maxv;
	i->openmin = 0;
	i->openmax = 0;
	i->integer = 1;
	i->empty = 0;
	return 0;
}

/* Aligne le plugin ALSA de PipeWire sur la période d'Organum. Le plugin
   lit PIPEWIRE_LATENCY à l'ouverture du PCM ; sans cela, il choisit sa
   propre latence (souvent le quantum du graphe) et le rythme d'écriture
   d'Organum ne correspond plus. Ne s'applique qu'au PCM « default », jamais
   à hw:, et ne remplace jamais une valeur fournie par l'utilisateur. */
int alsa_configurer_latence_pipewire(const char *nom, int periode, int taux)
{
	if (!nom || strcmp(nom, "default") != 0)
		return 0;
	if (periode <= 0 || taux <= 0)
		return 0;
	const char *deja = getenv("PIPEWIRE_LATENCY");
	if (deja && deja[0])
		return 0;
	char valeur[64];
	int n = snprintf(valeur, sizeof(valeur), "%d/%d", periode, taux);
	if (n < 0 || (size_t)n >= sizeof(valeur))
		return 0;
	if (setenv("PIPEWIRE_LATENCY", valeur, 1) != 0)
		return 0;
	return 1;
}

/* Tampon de conversion réutilisé : aucune allocation dans le fil audio.
   Dimensionné pour la période à l'ouverture, avec croissance contrôlée si
   une écriture plus grande arrive malgré tout. */
static int assurer_tampon(audio_t *audio, int trames)
{
	if (!audio || trames <= 0 || audio->fmt == 2)
		return 1;
	if (audio->canaux <= 0)
		return 0;
	size_t besoin = (size_t)trames * (size_t)audio->canaux;
	if (besoin / (size_t)audio->canaux != (size_t)trames)
		return 0;
	size_t capacite = audio->tampon_capacite;
	if (besoin <= capacite)
		return 1;
	size_t nouvelle = capacite ? capacite : 1;
	while (nouvelle < besoin) {
		if (nouvelle > ((size_t)-1) / 2) {
			nouvelle = besoin;
			break;
		}
		nouvelle *= 2;
	}
	size_t taille_element = (audio->fmt == 1) ? sizeof(int32_t) : sizeof(short);
	if (nouvelle > ((size_t)-1) / taille_element)
		return 0;
	void *tampon = realloc(audio->tampon, nouvelle * taille_element);
	if (!tampon)
		return 0;
	audio->tampon = tampon;
	audio->tampon_capacite = nouvelle;
	return 1;
}

static void convertir_s16(const float *source, short *destination, size_t n)
{
	for (size_t i = 0; i < n; i++) {
		float v = source[i];
		if (v > 1.0f) v = 1.0f;
		if (v < -1.0f) v = -1.0f;
		long s = (long)lrintf(v * 32767.0f);
		if (s > 32767) s = 32767;
		if (s < -32768) s = -32768;
		destination[i] = (short)s;
	}
}

static void convertir_s32(const float *source, int32_t *destination, size_t n)
{
	for (size_t i = 0; i < n; i++) {
		float v = source[i];
		if (v > 1.0f) v = 1.0f;
		if (v < -1.0f) v = -1.0f;
		long s = (long)lrintf(v * 2147483647.0f);
		if (s > 2147483647) s = 2147483647;
		if (s < -2147483648) s = -2147483648;
		destination[i] = (int32_t)s;
	}
}

/* ---------- audio_ouvrir ---------- */

audio_t *alsa_audio_ouvrir(const char *peripherique, int taux, int canaux, int periode, int nb_periodes)
{
	/* Une nouvelle tentative d'ouverture ne doit pas hériter du diagnostic
	   d'une tentative précédente ; l'erreur de chargement, elle, est
	   persistante. Effacé avant la garde de plate-forme pour qu'un échec
	   précoce ne laisse pas un message périmé. */
	erreur_effacer(erreur_ouverture);

#if defined(__COSMOPOLITAN__)
	if (!IsLinux()) {
		errno = ENOSYS;
		return NULL;
	}
#endif

	const char *name = (peripherique && peripherique[0]) ? peripherique : "default";

	int use_ioctl = 0;
	if (strncmp(name, "hw:", 3) == 0) {
		use_ioctl = 1;
	}

	if (!use_ioctl) {
		/* À faire avant snd_pcm_open : le plugin PipeWire lit cette
		   variable à l'ouverture. hw: passe par le chemin ioctl et ne
		   doit pas la recevoir. */
		alsa_configurer_latence_pipewire(name, periode, taux);
		if (!libasound_load()) {
			errno = ENODEV;
			return NULL;
		}
	}

	audio_t *audio = calloc(1, sizeof(audio_t));
	if (!audio) {
		errno = ENOMEM;
		erreur_ajouter(erreur_ouverture, sizeof(erreur_ouverture),
		               "mémoire insuffisante");
		return NULL;
	}
	audio->xruns = 0;
	audio->canaux = canaux;
	audio->taux = taux;
	audio->periode = periode;
	audio->nb_periodes = nb_periodes;
	audio->fmt = 0;
	audio->fd = -1;

	if (use_ioctl) {
		audio->chemin = 0;

		char chemin[256];
		if (!alsa_construire_chemin_hw(name, chemin, sizeof(chemin))) {
			errno = ENAMETOOLONG;
			erreur_ajouter(erreur_ouverture, sizeof(erreur_ouverture),
			               "nom de périphérique ALSA trop long : %s", name);
			free(audio);
			return NULL;
		}

		/* PipeWire peut détenir le PCM : un open() bloquant attend alors
		   indéfiniment. Ouvrir sans bloquer, puis revenir en mode bloquant
		   après HW_PARAMS (les ioctl d'écriture attendent un tampon libre). */
		int fd = systeme.sys_open(chemin, O_WRONLY | O_NONBLOCK);
		if (fd < 0) {
			int err = errno;
			erreur_effacer(erreur_ouverture);
			if (err == EAGAIN || err == EBUSY)
				erreur_ajouter(erreur_ouverture, sizeof(erreur_ouverture),
				               "%s occupé par un autre serveur audio "
				               "(PipeWire ?) ; utilisez le périphérique ALSA "
				               "« default »", chemin);
			else
				erreur_ajouter(erreur_ouverture, sizeof(erreur_ouverture),
				               "open(%s) : %s", chemin, strerror(err));
			errno = err;
			free(audio);
			return NULL;
		}
		audio->fd = fd;

		int ok = 0;
		for (int essai = 0; essai < 2; essai++) {
			snd_pcm_format_t fmt_essai = (essai == 0) ? SNDRV_PCM_FORMAT_S16_LE : SNDRV_PCM_FORMAT_S32_LE;
			struct snd_pcm_hw_params params;
			memset(&params, 0, sizeof(params));
			params.rmask = ~0u;
			audio_set_mask(&params, SNDRV_PCM_HW_PARAM_ACCESS, SNDRV_PCM_ACCESS_RW_INTERLEAVED);
			audio_set_mask(&params, SNDRV_PCM_HW_PARAM_FORMAT, fmt_essai);
			audio_set_interval(&params, SNDRV_PCM_HW_PARAM_CHANNELS, canaux, canaux);
			audio_set_interval(&params, SNDRV_PCM_HW_PARAM_RATE, taux, taux);
			audio_set_interval(&params, SNDRV_PCM_HW_PARAM_PERIOD_SIZE, periode, periode);
			audio_set_interval(&params, SNDRV_PCM_HW_PARAM_PERIODS, nb_periodes, nb_periodes);

			systeme.sys_ioctl(fd, SNDRV_PCM_IOCTL_HW_REFINE, &params);

			memset(&params, 0, sizeof(params));
			audio_set_mask(&params, SNDRV_PCM_HW_PARAM_ACCESS, SNDRV_PCM_ACCESS_RW_INTERLEAVED);
			audio_set_mask(&params, SNDRV_PCM_HW_PARAM_FORMAT, fmt_essai);
			audio_set_interval(&params, SNDRV_PCM_HW_PARAM_CHANNELS, canaux, canaux);
			audio_set_interval(&params, SNDRV_PCM_HW_PARAM_RATE, taux, taux);
			audio_set_interval(&params, SNDRV_PCM_HW_PARAM_PERIOD_SIZE, periode, periode);
			audio_set_interval(&params, SNDRV_PCM_HW_PARAM_PERIODS, nb_periodes, nb_periodes);

			if (systeme.sys_ioctl(fd, SNDRV_PCM_IOCTL_HW_PARAMS, &params) == 0) {
				audio->fmt = (fmt_essai == SNDRV_PCM_FORMAT_S32_LE) ? 1 : 0;
				ok = 1;
				break;
			}
		}

		if (!ok) {
			int err = errno;
			if (err == 0)
				err = EIO;
			erreur_effacer(erreur_ouverture);
			erreur_ajouter(erreur_ouverture, sizeof(erreur_ouverture),
			               "HW_PARAMS(%s) : %s", chemin, strerror(err));
			systeme.sys_close(fd);
			free(audio);
			errno = err;
			return NULL;
		}

		/* HW_PARAMS réussi : HW_PARAMS n'a pas besoin d'attendre, mais les
		   ioctl suivants (SW_PARAMS, PREPARE, WRITEI) attendent un tampon
		   libre. Revenir en mode bloquant comme avec un open() classique. */
		int drapeaux = systeme.sys_fcntl(fd, F_GETFL);
		if (drapeaux < 0 ||
		    systeme.sys_fcntl(fd, F_SETFL, drapeaux & ~O_NONBLOCK) < 0) {
			int err = errno;
			erreur_effacer(erreur_ouverture);
			erreur_ajouter(erreur_ouverture, sizeof(erreur_ouverture),
			               "fcntl(%s) : %s", chemin, strerror(err));
			systeme.sys_close(fd);
			free(audio);
			errno = err;
			return NULL;
		}

		{
			struct snd_pcm_sw_params sw;
			memset(&sw, 0, sizeof(sw));
			sw.start_threshold = (snd_pcm_uframes_t)1;
			sw.stop_threshold = (snd_pcm_uframes_t)-1;
			sw.avail_min = (snd_pcm_uframes_t)periode;
			systeme.sys_ioctl(fd, SNDRV_PCM_IOCTL_SW_PARAMS, &sw);
		}

		systeme.sys_ioctl(fd, SNDRV_PCM_IOCTL_PREPARE, NULL);

		if (!assurer_tampon(audio, periode)) {
			erreur_effacer(erreur_ouverture);
			erreur_ajouter(erreur_ouverture, sizeof(erreur_ouverture),
			               "mémoire insuffisante pour le tampon audio");
			systeme.sys_close(fd);
			free(audio->tampon);
			free(audio);
			errno = ENOMEM;
			return NULL;
		}
		return audio;
	}

	/* chemin libasound */
	audio->chemin = 1;

	snd_pcm_t *pcm = NULL;
	char namebuf[256];
	snprintf(namebuf, sizeof(namebuf), "%s", name);

	int err = p_snd_pcm_open(&pcm, namebuf, SND_PCM_STREAM_PLAYBACK, 0);
	if (err < 0) {
		const char *detail = p_snd_strerror ? p_snd_strerror(err) : NULL;
		erreur_effacer(erreur_ouverture);
		erreur_ajouter(erreur_ouverture, sizeof(erreur_ouverture),
		               "snd_pcm_open(%s) : %s", name,
		               (detail && detail[0]) ? detail : strerror(-err));
		errno = -err;
		free(audio);
		return NULL;
	}

	/* Latence du tampon ALSA cohérente avec la période demandée : la
	   période vaut periode trames et le tampon periode * nb_periodes.
	   L'ancienne valeur fixe de 50 ms ne correspondait ni au quantum ni
	   à la période d'écriture d'Organum. */
	long long latence_us = ((long long)periode * (long long)nb_periodes * 1000000LL
	                        + (long long)taux - 1) / (long long)taux;
	if (latence_us < 1000)
		latence_us = 1000;
	int formats[2] = { SND_PCM_FORMAT_FLOAT_LE, SND_PCM_FORMAT_S16_LE };
	int chosen = -1;
	for (int i = 0; i < 2; i++) {
		err = p_snd_pcm_set_params(pcm, formats[i], SND_PCM_ACCESS_RW_INTERLEAVED,
		                           (unsigned int)canaux, (unsigned int)taux, 1,
		                           (unsigned int)latence_us);
		if (err >= 0) {
			chosen = formats[i];
			break;
		}
	}

	if (chosen < 0) {
		const char *detail = p_snd_strerror ? p_snd_strerror(err) : NULL;
		erreur_effacer(erreur_ouverture);
		erreur_ajouter(erreur_ouverture, sizeof(erreur_ouverture),
		               "snd_pcm_set_params(%s) : %s", name,
		               (detail && detail[0]) ? detail : strerror((err < 0) ? -err : EIO));
		if (p_snd_pcm_close) p_snd_pcm_close(pcm);
		errno = (err < 0) ? -err : EIO;
		free(audio);
		return NULL;
	}

	if (chosen == SND_PCM_FORMAT_FLOAT_LE) {
		audio->fmt = 2;
	} else {
		audio->fmt = 0;
	}
	if (!assurer_tampon(audio, periode)) {
		erreur_effacer(erreur_ouverture);
		erreur_ajouter(erreur_ouverture, sizeof(erreur_ouverture),
		               "mémoire insuffisante pour le tampon audio");
		p_snd_pcm_close(pcm);
		free(audio->tampon);
		free(audio);
		errno = ENOMEM;
		return NULL;
	}
	audio->pcm = pcm;

	return audio;
}

/* ---------- audio_ecrire ---------- */

#define ALSA_ECRITURE_ESSAIS_MAX 1000
#define ALSA_ATTENTE_MS 10

int alsa_audio_ecrire(audio_t *audio, const float *entrelace, int trames)
{
	if (!audio || !entrelace || trames <= 0) {
		return -EINVAL;
	}

	if (!assurer_tampon(audio, trames)) {
		errno = ENOMEM;
		return -ENOMEM;
	}

	if (audio->chemin == 1) {
		snd_pcm_t *pcm = (snd_pcm_t *)audio->pcm;
		int canaux = audio->canaux;

		const char *source;
		size_t octets_trame;
		if (audio->fmt == 0) {
			convertir_s16(entrelace, (short *)audio->tampon,
			              (size_t)trames * (size_t)canaux);
			source = (const char *)audio->tampon;
			octets_trame = sizeof(short) * (size_t)canaux;
		} else if (audio->fmt == 1) {
			convertir_s32(entrelace, (int32_t *)audio->tampon,
			              (size_t)trames * (size_t)canaux);
			source = (const char *)audio->tampon;
			octets_trame = sizeof(int32_t) * (size_t)canaux;
		} else {
			source = (const char *)entrelace;
			octets_trame = sizeof(float) * (size_t)canaux;
		}

		int written = 0;
		int essais = 0;
		while (written < trames) {
			snd_pcm_sframes_t w = pcm_ecrire(
				pcm, source + (size_t)written * octets_trame,
				(snd_pcm_uframes_t)(trames - written));
			if (w > 0) {
				written += (int)w;
				essais = 0;
				continue;
			}
			if (w == -EPIPE) {
				audio->xruns++;
				if (++essais > ALSA_ECRITURE_ESSAIS_MAX) {
					errno = EPIPE;
					return -EPIPE;
				}
				int rec = pcm_recuperer(pcm, (int)w);
				if (rec < 0) {
					errno = -rec;
					return rec;
				}
				continue;
			}
			if (w == 0 || w == -EAGAIN) {
				if (++essais > ALSA_ECRITURE_ESSAIS_MAX) {
					errno = EAGAIN;
					return -EAGAIN;
				}
				/* Ne jamais jeter les trames restantes : attendre que
				   le PCM redevienne disponible puis réessayer. */
				pcm_attendre(pcm, ALSA_ATTENTE_MS);
				continue;
			}
			if (w == -EINTR) {
				if (++essais > ALSA_ECRITURE_ESSAIS_MAX) {
					errno = EINTR;
					return -EINTR;
				}
				continue;
			}
			errno = (int)-w;
			return (int)w;
		}
		return written;
	}

	/* ioctl : mêmes tampons de conversion réutilisés, sans malloc/free par
	   période. Le PCM est bloquant après HW_PARAMS : l'ioctl attend un
	   tampon libre. */
	int canaux = audio->canaux;
	size_t total_echantillons = (size_t)trames * (size_t)canaux;

	if (audio->fmt == 0) {
		short *buf = (short *)audio->tampon;
		convertir_s16(entrelace, buf, total_echantillons);
		struct snd_xferi xfer;
		xfer.buf = buf;
		xfer.frames = (snd_pcm_uframes_t)trames;
		int ret = systeme.sys_ioctl(audio->fd, SNDRV_PCM_IOCTL_WRITEI_FRAMES, &xfer);
		if (ret < 0) {
			int err = errno;
			if (err == EPIPE) {
				audio->xruns++;
				if (systeme.sys_ioctl(audio->fd, SNDRV_PCM_IOCTL_PREPARE, NULL) >= 0) {
					xfer.buf = buf;
					xfer.frames = (snd_pcm_uframes_t)trames;
					ret = systeme.sys_ioctl(audio->fd, SNDRV_PCM_IOCTL_WRITEI_FRAMES, &xfer);
					if (ret >= 0)
						return ret;
				}
			}
			errno = err;
			return -err;
		}
		return ret;
	}

	int32_t *buf = (int32_t *)audio->tampon;
	convertir_s32(entrelace, buf, total_echantillons);
	struct snd_xferi xfer;
	xfer.buf = buf;
	xfer.frames = (snd_pcm_uframes_t)trames;
	int ret = systeme.sys_ioctl(audio->fd, SNDRV_PCM_IOCTL_WRITEI_FRAMES, &xfer);
	if (ret < 0) {
		int err = errno;
		if (err == EPIPE) {
			audio->xruns++;
			if (systeme.sys_ioctl(audio->fd, SNDRV_PCM_IOCTL_PREPARE, NULL) >= 0) {
				xfer.buf = buf;
				xfer.frames = (snd_pcm_uframes_t)trames;
				ret = systeme.sys_ioctl(audio->fd, SNDRV_PCM_IOCTL_WRITEI_FRAMES, &xfer);
				if (ret >= 0)
					return ret;
			}
		}
		errno = err;
		return -err;
	}
	return ret;
}

int alsa_audio_xruns(audio_t *audio)
{
	if (!audio)
		return 0;
	return audio->xruns;
}

void alsa_audio_fermer(audio_t *audio)
{
	if (!audio)
		return;
	if (audio->chemin == 1) {
		if (audio->pcm && p_snd_pcm_close) {
			p_snd_pcm_close((snd_pcm_t *)audio->pcm);
		}
	} else {
		if (audio->fd >= 0) {
			systeme.sys_close(audio->fd);
		}
	}
	free(audio->tampon);
	free(audio);
}

const char *alsa_audio_chemin(audio_t *audio)
{
	if (!audio) return "inconnu";
	return (audio->chemin == 1) ? "libasound" : "ioctl";
}

const char *alsa_audio_format(audio_t *audio)
{
	if (!audio) return "inconnu";
	if (audio->fmt == 2) return "FLOAT_LE";
	if (audio->fmt == 1) return "S32_LE";
	return "S16_LE";
}

/* Création d'un contexte factice du chemin libasound, réservée aux tests de
   la boucle d'écriture : aucun PCM réel n'est ouvert. */
audio_t *alsa_audio_creer_pour_test(int canaux, int periode, int fmt)
{
	audio_t *audio = calloc(1, sizeof(*audio));
	if (!audio)
		return NULL;
	audio->chemin = 1;
	audio->canaux = canaux;
	audio->taux = 48000;
	audio->periode = periode;
	audio->nb_periodes = 1;
	audio->fmt = fmt;
	audio->fd = -1;
	if (!assurer_tampon(audio, periode)) {
		free(audio);
		return NULL;
	}
	return audio;
}
