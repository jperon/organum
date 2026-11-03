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

static snd_pcm_open_t p_snd_pcm_open = NULL;
static snd_pcm_set_params_t p_snd_pcm_set_params = NULL;
static snd_pcm_writei_t p_snd_pcm_writei = NULL;
static snd_pcm_recover_t p_snd_pcm_recover = NULL;
static snd_pcm_close_t p_snd_pcm_close = NULL;
static snd_strerror_t p_snd_strerror = NULL;
static snd_pcm_prepare_t p_snd_pcm_prepare = NULL;

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

	int formats[2] = { SND_PCM_FORMAT_FLOAT_LE, SND_PCM_FORMAT_S16_LE };
	int chosen = -1;
	for (int i = 0; i < 2; i++) {
		err = p_snd_pcm_set_params(pcm, formats[i], SND_PCM_ACCESS_RW_INTERLEAVED,
		                           (unsigned int)canaux, (unsigned int)taux, 1, 50000);
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
	audio->pcm = pcm;

	return audio;
}

/* ---------- audio_ecrire ---------- */

int alsa_audio_ecrire(audio_t *audio, const float *entrelace, int trames)
{
	if (!audio || !entrelace || trames <= 0) {
		return -EINVAL;
	}

	if (audio->chemin == 1) {
		snd_pcm_t *pcm = (snd_pcm_t *)audio->pcm;
		int canaux = audio->canaux;

		short *s16buf = NULL;
		if (audio->fmt == 0) {
			s16buf = malloc((size_t)trames * canaux * sizeof(short));
			if (!s16buf) return -ENOMEM;
			for (int i = 0; i < trames * canaux; i++) {
				float v = entrelace[i];
				if (v > 1.0f) v = 1.0f;
				if (v < -1.0f) v = -1.0f;
				long s = (long)lrintf(v * 32767.0f);
				if (s > 32767) s = 32767;
				if (s < -32768) s = -32768;
				s16buf[i] = (short)s;
			}
		}

		int written = 0;
		while (written < trames) {
			snd_pcm_sframes_t w;
			if (audio->fmt == 2) {
				w = p_snd_pcm_writei(pcm, entrelace + (size_t)written * canaux, (snd_pcm_uframes_t)(trames - written));
			} else {
				w = p_snd_pcm_writei(pcm, s16buf + (size_t)written * canaux, (snd_pcm_uframes_t)(trames - written));
			}
			if (w < 0) {
				if (w == -EPIPE) {
					audio->xruns++;
					int rec = p_snd_pcm_recover(pcm, (int)w, 1);
					if (rec >= 0) {
						continue;
					}
				}
				if (s16buf) free(s16buf);
				errno = (int)-w;
				return (int)w;
			}
			if (w == 0) {
				break;
			}
			written += (int)w;
		}
		if (s16buf) free(s16buf);
		return written;
	}

	/* ioctl */
	int canaux = audio->canaux;
	int total_echantillons = trames * canaux;

	if (audio->fmt == 0) {
		short *buf = malloc(total_echantillons * sizeof(short));
		if (!buf) return -ENOMEM;
		for (int i = 0; i < total_echantillons; i++) {
			float v = entrelace[i];
			if (v > 1.0f) v = 1.0f;
			if (v < -1.0f) v = -1.0f;
			long s = (long)lrintf(v * 32767.0f);
			if (s > 32767) s = 32767;
			if (s < -32768) s = -32768;
			buf[i] = (short)s;
		}
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
					if (ret >= 0) {
						free(buf);
						return ret;
					}
				}
			}
			free(buf);
			errno = err;
			return -err;
		}
		free(buf);
		return ret;
	} else {
		int32_t *buf = malloc(total_echantillons * sizeof(int32_t));
		if (!buf) return -ENOMEM;
		for (int i = 0; i < total_echantillons; i++) {
			float v = entrelace[i];
			if (v > 1.0f) v = 1.0f;
			if (v < -1.0f) v = -1.0f;
			long s = (long)lrintf(v * 2147483647.0f);
			if (s > 2147483647) s = 2147483647;
			if (s < -2147483648) s = -2147483648;
			buf[i] = (int32_t)s;
		}
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
					if (ret >= 0) {
						free(buf);
						return ret;
					}
				}
			}
			free(buf);
			errno = err;
			return -err;
		}
		free(buf);
		return ret;
	}
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
