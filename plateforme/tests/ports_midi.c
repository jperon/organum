/* Vérifie l'énumération des ports MIDI, les abonnements explicites et la
   liste des adresses exclues de la reconnexion automatique. Aucun accès à
   /dev/snd : les ioctl du séquenceur sont simulés par l'en-tête interne de
   midi_alsa.c. */
#include "../backends.h"
#include "../linux/asequencer_min.h"
#include "../linux/midi_alsa_interne.h"

#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#define NB_CLIENTS 5
#define NB_ABONNEMENTS 16

struct faux_port {
	int port;
	const char *nom;
	unsigned int capacites;
	unsigned int type;
};

struct faux_client {
	int client;
	const char *nom;
	int nports;
	struct faux_port ports[2];
};

static const struct faux_client clients[NB_CLIENTS] = {
	{0, "Système", 1, {{1, "Annonces",
	                    SNDRV_SEQ_PORT_CAP_READ | SNDRV_SEQ_PORT_CAP_WRITE |
	                        SNDRV_SEQ_PORT_CAP_SUBS_READ | SNDRV_SEQ_PORT_CAP_SUBS_WRITE,
	                    SNDRV_SEQ_PORT_TYPE_MIDI_GENERIC}}},
	{20, "Clavier", 1, {{0, "entrée", SNDRV_SEQ_PORT_CAP_READ | SNDRV_SEQ_PORT_CAP_SUBS_READ,
	                     SNDRV_SEQ_PORT_TYPE_MIDI_GENERIC}}},
	{21, "Synthé", 1, {{0, "sortie", SNDRV_SEQ_PORT_CAP_WRITE | SNDRV_SEQ_PORT_CAP_SUBS_WRITE,
	                    SNDRV_SEQ_PORT_TYPE_MIDI_GENERIC}}},
	{22, "Contrôle", 1, {{0, "curseur", SNDRV_SEQ_PORT_CAP_READ,
	                      SNDRV_SEQ_PORT_TYPE_MIDI_GENERIC}}},
	{128, "Organum", 1, {{0, "entree", SNDRV_SEQ_PORT_CAP_WRITE | SNDRV_SEQ_PORT_CAP_SUBS_WRITE,
	                      SNDRV_SEQ_PORT_TYPE_MIDI_GENERIC | SNDRV_SEQ_PORT_TYPE_APPLICATION}}},
};

struct abonnement {
	int client, port;
	int dest_client, dest_port;
};

static struct {
	int echec_open;
	int vide;
	int fd;
	int nb_close;
	struct abonnement abonnements[NB_ABONNEMENTS];
	int nabonnements;
} etat;

static int echecs;

static void verifier(int condition, const char *message)
{
	if (condition) {
		printf("OK %s\n", message);
	} else {
		fprintf(stderr, "ERREUR : %s\n", message);
		echecs++;
	}
}

static const struct faux_client *client_par_id(int id)
{
	for (int i = 0; i < NB_CLIENTS; ++i)
		if (clients[i].client == id)
			return &clients[i];
	return NULL;
}

static int test_open(const char *chemin, int drapeaux, ...)
{
	(void)chemin;
	(void)drapeaux;
	if (etat.echec_open) {
		errno = ENOENT;
		return -1;
	}
	return etat.fd;
}

static int test_close(int fd)
{
	(void)fd;
	etat.nb_close++;
	return 0;
}

static struct abonnement *trouver_abonnement(int client, int port,
					      int dest_client, int dest_port)
{
	for (int i = 0; i < etat.nabonnements; ++i)
		if (etat.abonnements[i].client == client && etat.abonnements[i].port == port &&
		    etat.abonnements[i].dest_client == dest_client &&
		    etat.abonnements[i].dest_port == dest_port)
			return &etat.abonnements[i];
	return NULL;
}

static int test_ioctl(int fd, unsigned long requete, ...)
{
	(void)fd;
	va_list ap;
	va_start(ap, requete);
	void *arg = va_arg(ap, void *);
	va_end(ap);

	switch (requete) {
	case SNDRV_SEQ_IOCTL_CLIENT_ID:
		*(int *)arg = 128;
		return 0;
	case SNDRV_SEQ_IOCTL_SET_CLIENT_INFO:
		return 0;
	case SNDRV_SEQ_IOCTL_CREATE_PORT:
		((struct snd_seq_port_info *)arg)->addr.port = 0;
		return 0;
	case SNDRV_SEQ_IOCTL_QUERY_NEXT_CLIENT: {
		struct snd_seq_client_info *c = arg;
		if (etat.vide) {
			errno = ENOENT;
			return -1;
		}
		for (int i = 0; i < NB_CLIENTS; ++i) {
			if (clients[i].client <= c->client)
				continue;
			memset(c, 0, sizeof(*c));
			c->client = clients[i].client;
			c->type = 1;
			snprintf(c->name, sizeof(c->name), "%s", clients[i].nom);
			return 0;
		}
		errno = ENOENT;
		return -1;
	}
	case SNDRV_SEQ_IOCTL_QUERY_NEXT_PORT: {
		struct snd_seq_port_info *p = arg;
		const struct faux_client *c = client_par_id(p->addr.client);
		if (!c) {
			errno = ENOENT;
			return -1;
		}
		/* p.addr.port est un octet : -1 y devient 255, sentinelle du
		   noyau pour « depuis le début ». */
		int apres = p->addr.port == 255 ? -1 : p->addr.port;
		for (int i = 0; i < c->nports; ++i) {
			if (c->ports[i].port <= apres)
				continue;
			memset(p, 0, sizeof(*p));
			p->addr.client = c->client;
			p->addr.port = c->ports[i].port;
			snprintf(p->name, sizeof(p->name), "%s", c->ports[i].nom);
			p->capability = c->ports[i].capacites;
			p->type = c->ports[i].type;
			return 0;
		}
		errno = ENOENT;
		return -1;
	}
	case SNDRV_SEQ_IOCTL_GET_PORT_INFO: {
		struct snd_seq_port_info *p = arg;
		const struct faux_client *c = client_par_id(p->addr.client);
		if (!c) {
			errno = ENOENT;
			return -1;
		}
		for (int i = 0; i < c->nports; ++i) {
			if (c->ports[i].port != p->addr.port)
				continue;
			snprintf(p->name, sizeof(p->name), "%s", c->ports[i].nom);
			p->capability = c->ports[i].capacites;
			p->type = c->ports[i].type;
			return 0;
		}
		errno = ENOENT;
		return -1;
	}
	case SNDRV_SEQ_IOCTL_SUBSCRIBE_PORT: {
		struct snd_seq_port_subscribe *s = arg;
		if (trouver_abonnement(s->sender.client, s->sender.port,
				       s->dest.client, s->dest.port)) {
			errno = EBUSY;
			return -1;
		}
		if (etat.nabonnements >= NB_ABONNEMENTS) {
			errno = ENOSPC;
			return -1;
		}
		etat.abonnements[etat.nabonnements].client = s->sender.client;
		etat.abonnements[etat.nabonnements].port = s->sender.port;
		etat.abonnements[etat.nabonnements].dest_client = s->dest.client;
		etat.abonnements[etat.nabonnements].dest_port = s->dest.port;
		etat.nabonnements++;
		return 0;
	}
	case SNDRV_SEQ_IOCTL_UNSUBSCRIBE_PORT: {
		struct snd_seq_port_subscribe *s = arg;
		struct abonnement *a = trouver_abonnement(s->sender.client, s->sender.port,
							  s->dest.client, s->dest.port);
		if (!a) {
			errno = ENOENT;
			return -1;
		}
		*a = etat.abonnements[--etat.nabonnements];
		return 0;
	}
	case SNDRV_SEQ_IOCTL_GET_SUBSCRIPTION: {
		struct snd_seq_port_subscribe *s = arg;
		/* Le destinataire fait partie de la clé : un abonnement au même
		   émetteur mais vers un autre client ne doit pas être vu comme
		   connecté à Organum. */
		if (!trouver_abonnement(s->sender.client, s->sender.port,
					s->dest.client, s->dest.port)) {
			errno = ENOENT;
			return -1;
		}
		return 0;
	}
	default:
		errno = EINVAL;
		return -1;
	}
}

static void installer(void)
{
	struct midi_alsa_systeme systeme = {
		.sys_open = test_open,
		.sys_close = test_close,
		.sys_ioctl = test_ioctl,
	};
	alsa_midi_injecter_systeme(&systeme);
}

static struct midi_port *trouver_port(struct midi_port *ports, int n,
				      int client, int port)
{
	for (int i = 0; i < n; ++i)
		if (ports[i].client == client && ports[i].port == port)
			return &ports[i];
	return NULL;
}

static int enumerer(midi_t *midi, struct midi_port *ports)
{
	int n = midi_ports(midi, ports, MIDI_MAX_PORTS);
	if (n < 0) {
		fprintf(stderr, "ERREUR : énumération refusée : %s\n", strerror(errno));
		echecs++;
		return 0;
	}
	return n;
}

/* Complément facultatif : si un vrai séquenceur est accessible, vérifie les
   mêmes opérations sur le noyau (sans toucher à la configuration MIDI de
   l'utilisateur). Sinon le test s'auto-ignore. */
static void verifier_sequenceur_reel(void)
{
	struct midi_port ports[MIDI_MAX_PORTS];
	midi_t *midi = midi_ouvrir("Organum-test-ports", "test");
	if (!midi) {
		printf("IGNORÉ : séquenceur MIDI indisponible (%s)\n", strerror(errno));
		return;
	}
	int n = midi_ports(midi, ports, MIDI_MAX_PORTS);
	if (n < 0) {
		fprintf(stderr, "ERREUR : énumération réelle refusée : %s\n", strerror(errno));
		echecs++;
		midi_fermer(midi);
		return;
	}
	int client = -1, port = -1;
	if (midi_adresse(midi, &client, &port) < 0) {
		fprintf(stderr, "ERREUR : adresse du port d'Organum inconnue : %s\n",
		        strerror(errno));
		echecs++;
		midi_fermer(midi);
		return;
	}
	struct midi_port *organum = trouver_port(ports, n, client, port);
	if (organum) {
		verifier(organum->organum, "port d'Organum retrouvé à son adresse réelle");
	} else if (n >= MIDI_MAX_PORTS) {
		printf("IGNORÉ : port d'Organum hors des %d premiers ports énumérés\n",
		       MIDI_MAX_PORTS);
	} else {
		fprintf(stderr, "ERREUR : port d'Organum %d:%d absent de la liste réelle\n",
		        client, port);
		echecs++;
	}

	if (midi_connecter(midi, 0, 1) == 0) {
		n = enumerer(midi, ports);
		struct midi_port *p = trouver_port(ports, n, 0, 1);
		verifier(p && p->connecte, "abonnement réel aux annonces visible");
		errno = 0;
		verifier(midi_deconnecter(midi, 0, 1) == -1 && errno == EINVAL,
		         "désabonnement réel des annonces refusé");
	} else {
		printf("IGNORÉ : abonnement réel aux annonces (%s)\n", strerror(errno));
	}
	midi_fermer(midi);
}

int main(void)
{
	struct midi_port ports[MIDI_MAX_PORTS];
	struct midi_port petit[2];
	struct midi_port *p;
	midi_t *midi;

	memset(&etat, 0, sizeof(etat));
	etat.fd = 42;
	installer();

	midi = midi_ouvrir("Organum", "entree");
	if (!midi) {
		fprintf(stderr, "ERREUR : ouverture simulée refusée\n");
		return 1;
	}

	verifier(midi_ports(NULL, NULL, 0) == -1, "énumération sans client refusée");
	verifier(midi_ports(midi, NULL, 0) == 0, "maximum nul accepté sans tampon");
	verifier(midi_ports(midi, NULL, 1) == -1, "tampon nul refusé");

	int n = enumerer(midi, ports);
	verifier(n == NB_CLIENTS, "les cinq ports sont énumérés");

	p = trouver_port(ports, n, 20, 0);
	verifier(p && p->source && !p->destination && !p->connecte && !p->organum &&
	             p->lecture && p->abonnement && p->generique,
	         "clavier : source abonnable, non connecté");
	verifier(p && strcmp(p->nom_client, "Clavier") == 0 &&
	             strcmp(p->nom_port, "entrée") == 0,
	         "noms du client et du port conservés");

	p = trouver_port(ports, n, 21, 0);
	verifier(p && !p->source && p->destination && !p->connecte,
	         "synthé : destination, pas source");

	p = trouver_port(ports, n, 22, 0);
	verifier(p && !p->source && !p->abonnement, "port lisible non abonnable exclu des sources");

	p = trouver_port(ports, n, 128, 0);
	verifier(p && p->organum && !p->connecte, "port d'Organum signalé");

	p = trouver_port(ports, n, 0, 1);
	verifier(p && !p->source, "annonces du système exclues des sources");

	verifier(midi_connecter(midi, 20, 0) == 0, "connexion explicite du clavier");
	n = enumerer(midi, ports);
	p = trouver_port(ports, n, 20, 0);
	verifier(p && p->connecte, "état connecté publié");
	verifier(midi_connecter(midi, 20, 0) == 0, "connexion déjà existante acceptée");

	struct snd_seq_port_subscribe mauvais_dest;
	memset(&mauvais_dest, 0, sizeof(mauvais_dest));
	mauvais_dest.sender.client = 20;
	mauvais_dest.sender.port = 0;
	mauvais_dest.dest.client = 128;
	mauvais_dest.dest.port = 99;
	errno = 0;
	verifier(test_ioctl(etat.fd, SNDRV_SEQ_IOCTL_GET_SUBSCRIPTION, &mauvais_dest) == -1 &&
	             errno == ENOENT,
	         "abonnement vers un autre destinataire non confondu avec Organum");

	verifier(midi_deconnecter(midi, 20, 0) == 0, "déconnexion explicite");
	n = enumerer(midi, ports);
	p = trouver_port(ports, n, 20, 0);
	verifier(p && !p->connecte, "état déconnecté publié");
	verifier(midi_deconnecter(midi, 20, 0) == 0, "déconnexion déjà faite acceptée");

	verifier(alsa_midi_connecter_automatique(midi, 20, 0) == 0,
	         "la reconnexion automatique respecte l'exclusion");
	n = enumerer(midi, ports);
	p = trouver_port(ports, n, 20, 0);
	verifier(p && !p->connecte, "clavier resté déconnecté");

	verifier(midi_connecter(midi, 20, 0) == 0, "reconnexion explicite après exclusion");
	verifier(midi_deconnecter(midi, 20, 0) == 0, "nouvelle déconnexion avant remise à zéro");

	verifier(alsa_midi_connecter_automatique(midi, 21, 0) == 0,
	         "une destination n'est jamais connectée automatiquement");
	verifier(trouver_abonnement(21, 0, 128, 0) == NULL,
	         "aucun abonnement vers la destination");

	verifier(midi_connecter_tout(midi) >= 1, "connexion automatique globale");
	n = enumerer(midi, ports);
	p = trouver_port(ports, n, 20, 0);
	verifier(p && p->connecte, "midi_connecter_tout efface les exclusions");
	p = trouver_port(ports, n, 21, 0);
	verifier(p && !p->connecte, "la destination reste hors connexion");

	/* Une exclusion publiée par un autre processus après la lecture de la
	   génération courante (q > seq) ne doit pas être prise pour périmée. */
	alsa_midi_tester_exclure_future(midi, 20, 0);
	verifier(alsa_midi_connecter_automatique(midi, 20, 0) == 0,
	         "exclusion de génération future respectée par la reconnexion");
	verifier(midi_connecter(midi, 20, 0) == 0,
	         "connexion explicite efface une exclusion de génération future");

	verifier(midi_ports(midi, petit, 2) == 2, "maximum respecté");
	verifier(midi_connecter(NULL, 20, 0) == -1 && errno == EINVAL,
	         "connexion sans client refusée");
	verifier(midi_deconnecter(NULL, 20, 0) == -1 && errno == EINVAL,
	         "déconnexion sans client refusée");

	errno = 0;
	verifier(midi_connecter(midi, 256, 0) == -1 && errno == EINVAL,
	         "client hors borne refusé (256:0)");
	errno = 0;
	verifier(midi_connecter(midi, 0, 256) == -1 && errno == EINVAL,
	         "port hors borne refusé (0:256)");
	errno = 0;
	verifier(midi_connecter(midi, -1, 0) == -1 && errno == EINVAL,
	         "client négatif refusé");
	errno = 0;
	verifier(midi_deconnecter(midi, 300, 0) == -1 && errno == EINVAL,
	         "déconnexion hors borne refusée");
	errno = 0;
	verifier(midi_deconnecter(midi, 0, 1) == -1 && errno == EINVAL,
	         "déconnexion des annonces du système refusée");

	midi_fermer(midi);
	verifier(etat.nb_close == 1, "descripteur fermé une fois");

	etat.echec_open = 1;
	verifier(midi_ouvrir("Organum", "entree") == NULL, "ouverture sans séquenceur refusée");
	etat.echec_open = 0;

	midi = midi_ouvrir("Organum", "entree");
	etat.vide = 1;
	verifier(midi_ports(midi, ports, MIDI_MAX_PORTS) == -1,
	         "échec d'énumération signalé");
	midi_fermer(midi);

	alsa_midi_injecter_systeme(NULL);
	verifier_sequenceur_reel();

	if (echecs) {
		fprintf(stderr, "%d erreur(s)\n", echecs);
		return 1;
	}
	printf("Ports MIDI : tous les cas sont corrects.\n");
	return 0;
}
