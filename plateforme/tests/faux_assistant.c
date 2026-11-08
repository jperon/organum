/* Faux assistant CoreMIDI pour les tests sous Linux.
 *
 * Organum parle à CoreMIDI par une socket Unix (voir
 * plateforme/macos/PROTOCOLE-MIDI.md). Ce programme joue le rôle de
 * l'assistant : il crée la socket, accepte un client, échange la poignée de
 * main, publie deux claviers fictifs (DEVICE_LIST) puis rejoue la séquence
 * demandée. Il inclut le même codec que le backend organum
 * (../macos/trames_midi.h) : le test prouve ainsi que l'encodeur et le
 * décodeur se comprennent, sans copie de la spécification.
 *
 * Usage :
 *   faux_assistant [--socket CHEMIN] [--sequence SÉQUENCE]
 *                  [--tomber-apres MS] [--refuser-version]
 *                  [--attendre-client MS]
 *
 * SÉQUENCE est une liste séparée par des virgules :
 *   note:canal:note:vitesse   message 0x9n (vitesse 0 = note OFF)
 *   cc:canal:contrôleur:valeur
 *   pc:canal:programme        Program Change 0xCn
 *   pause:millisecondes       attend en répondant aux PING
 *   ping                      envoie un PING à organum
 *
 * --tomber-apres ferme la connexion et sort après la séquence (une panne
 * simulée). --refuser-version répond le statut 1 et reste à l'écoute pour
 * montrer qu'organum ne boucle pas. --attendre-client borne l'attente du
 * premier client. SIGINT/SIGTERM arrêtent proprement.
 *
 * Compilation hôte, sans cosmocc :
 *   cc -O2 -Wall -Wextra -o faux_assistant plateforme/tests/faux_assistant.c
 */
#define _POSIX_C_SOURCE 200809L

#include "../macos/trames_midi.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0
#endif

#define MAX_FRAME 4096
#define TAMPON_LECTURE 512
#define DELAI_POIGNEE 5000
#define ATTENTE_CLIENT_DEFAUT 15000

static volatile sig_atomic_t arret;

static void sur_signal(int sig)
{
    (void)sig;
    arret = 1;
}

static long maintenant_ms(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (long)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

/* Écrit tout, sans jamais dépendre de SIGPIPE. Une trame de contrôle tient
   toujours dans le tampon de la socket ; un échec ferme la session. */
static int ecrire_tout(int fd, const void *octets, size_t n)
{
    const uint8_t *p = octets;
    size_t fait = 0;
    while (fait < n) {
        ssize_t w = send(fd, p + fait, n - fait, MSG_NOSIGNAL);
        if (w > 0) {
            fait += (size_t)w;
            continue;
        }
        if (w < 0 && errno == EINTR)
            continue;
        return -1;
    }
    return 0;
}

static int envoyer_trame(int fd, uint8_t type, uint8_t flags,
                         const uint8_t *corps, uint16_t longueur)
{
    uint8_t trame[TRAMES_MIDI_ENTETE_TAILLE + 256];
    if (longueur > 256)
        return -1;
    const int n = trame_encoder(trame, sizeof trame, type, flags, corps,
                                longueur);
    if (n < 0)
        return -1;
    return ecrire_tout(fd, trame, (size_t)n);
}

static void journal(const char *format, ...)
{
    va_list args;
    va_start(args, format);
    vfprintf(stdout, format, args);
    va_end(args);
    fputc('\n', stdout);
    fflush(stdout);
}

/* Lit exactement n octets, en abandonnant proprement sur signal. Renvoie 0,
   -1 sur fin/erreur, -2 sur expiration du délai. */
static int lire_exact(int fd, uint8_t *sortie, size_t n, long delai_ms)
{
    const long echeance = maintenant_ms() + delai_ms;
    size_t fait = 0;
    while (fait < n) {
        if (arret)
            return -1;
        long reste = echeance - maintenant_ms();
        if (reste < 0)
            return -2;
        struct pollfd p = {fd, POLLIN, 0};
        const int r = poll(&p, 1, (int)reste);
        if (r < 0) {
            if (errno == EINTR)
                continue;
            return -1;
        }
        if (r == 0)
            return -2;
        const ssize_t l = recv(fd, sortie + fait, n - fait, 0);
        if (l > 0)
            fait += (size_t)l;
        else if (l == 0)
            return -1;
        else if (errno != EINTR)
            return -1;
    }
    return 0;
}

struct lecture {
    int fd;
    struct trame_decodeur decodeur;
    uint8_t tampon[TAMPON_LECTURE];
    size_t debut, fin;
};

/* Traite toutes les trames complètes déjà présentes. Renvoie 0, ou -1 sur
   BYE, erreur de décodage ou demande d'arrêt. */
static int traiter_trames(struct lecture *l)
{
    for (;;) {
        struct trame_vue vue;
        size_t consommes = 0;
        const int code = trame_decoder(&l->decodeur, l->tampon + l->debut,
                                       l->fin - l->debut, &vue, &consommes);
        if (code < 0)
            return -1;
        if (code == 0) {
            /* Le décodeur a absorbé les octets incomplets : il n'y a plus
               rien à conserver dans notre tampon. */
            l->debut = l->fin = 0;
            return 0;
        }
        l->debut += consommes;
        switch (vue.type) {
        case TRAMES_MIDI_TYPE_PING:
            journal("PING reçu, PONG envoyé");
            if (envoyer_trame(l->fd, TRAMES_MIDI_TYPE_PONG, 0, NULL, 0) < 0)
                return -1;
            break;
        case TRAMES_MIDI_TYPE_SUBSCRIBE:
            if (vue.longueur >= 2)
                journal("SUBSCRIBE id=%u actif=%u", vue.corps[0],
                        vue.corps[1]);
            break;
        case TRAMES_MIDI_TYPE_BYE:
            journal("BYE reçu d'organum");
            return -1;
        default:
            /* MIDI, SYSEX, PONG, types inconnus : rien à faire ici. */
            break;
        }
        if (l->debut == l->fin)
            l->debut = l->fin = 0;
    }
}

/* Attend au plus delai_ms une entrée, traite ce qui arrive et rend la main
   dès qu'une lecture a eu lieu. Renvoie 0, ou -1 sur coupure/erreur. */
static int pomper(struct lecture *l, long delai_ms)
{
    if (traiter_trames(l) < 0)
        return -1;
    if (arret)
        return 0;
    if (delai_ms < 0)
        delai_ms = 0;
    struct pollfd p = {l->fd, POLLIN, 0};
    int r;
    do {
        r = poll(&p, 1, (int)delai_ms);
    } while (r < 0 && errno == EINTR && !arret);
    if (arret)
        return 0;
    if (r < 0)
        return -1;
    if (r == 0)
        return 0;
    if (l->debut == l->fin)
        l->debut = l->fin = 0;
    const ssize_t n = recv(l->fd, l->tampon + l->fin,
                           sizeof l->tampon - l->fin, 0);
    if (n == 0)
        return -1;
    if (n < 0)
        return (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) ? 0
                                                                          : -1;
    l->fin += (size_t)n;
    return traiter_trames(l);
}

/* Attend en continu, en répondant aux PING, jusqu'à l'échéance ou l'arrêt. */
static int attendre_avec_flux(struct lecture *l, long delai_ms)
{
    const long echeance = maintenant_ms() + delai_ms;
    for (;;) {
        if (arret)
            return 0;
        const long reste = echeance - maintenant_ms();
        if (reste <= 0)
            return 0;
        if (pomper(l, reste) < 0)
            return -1;
    }
}

static int envoyer_midi(int fd, const uint8_t *corps, uint16_t longueur)
{
    return envoyer_trame(fd, TRAMES_MIDI_TYPE_MIDI, 0, corps, longueur);
}

static int envoyer_device_list(int fd)
{
    static const char nom1[] = "Clavier fictif I";
    static const char nom2[] = "Clavier fictif II";
    uint8_t corps[256];
    size_t i = 0;
    corps[i++] = 2;
    corps[i++] = 1;
    corps[i++] = TRAMES_MIDI_CAPACITE_SOURCE;
    corps[i++] = (uint8_t)(sizeof nom1 - 1);
    memcpy(corps + i, nom1, sizeof nom1 - 1);
    i += sizeof nom1 - 1;
    corps[i++] = 2;
    corps[i++] = TRAMES_MIDI_CAPACITE_SOURCE;
    corps[i++] = (uint8_t)(sizeof nom2 - 1);
    memcpy(corps + i, nom2, sizeof nom2 - 1);
    i += sizeof nom2 - 1;
    return envoyer_trame(fd, TRAMES_MIDI_TYPE_DEVICE_LIST, 0, corps,
                         (uint16_t)i);
}

/* Analyse et envoie un élément de séquence. Renvoie 0, -1 si le jeton est
   invalide, 1 pour une pause déjà effectuée. */
static int jouer_jeton(struct lecture *l, const char *jeton)
{
    unsigned int canal, a, b, ms;
    if (sscanf(jeton, "note:%u:%u:%u", &canal, &a, &b) == 3) {
        if (canal > 15 || a > 127 || b > 127)
            goto invalide;
        const uint8_t corps[3] = {(uint8_t)(0x90 | canal), (uint8_t)a,
                                  (uint8_t)b};
        journal("note canal=%u note=%u vitesse=%u", canal, a, b);
        return envoyer_midi(l->fd, corps, 3);
    }
    if (sscanf(jeton, "cc:%u:%u:%u", &canal, &a, &b) == 3) {
        if (canal > 15 || a > 127 || b > 127)
            goto invalide;
        const uint8_t corps[3] = {(uint8_t)(0xB0 | canal), (uint8_t)a,
                                  (uint8_t)b};
        journal("cc canal=%u contrôleur=%u valeur=%u", canal, a, b);
        return envoyer_midi(l->fd, corps, 3);
    }
    if (sscanf(jeton, "pc:%u:%u", &canal, &a) == 2) {
        if (canal > 15 || a > 127)
            goto invalide;
        const uint8_t corps[2] = {(uint8_t)(0xC0 | canal), (uint8_t)a};
        journal("program change canal=%u programme=%u", canal, a);
        return envoyer_midi(l->fd, corps, 2);
    }
    if (sscanf(jeton, "pause:%u", &ms) == 1) {
        if (ms > 60000)
            goto invalide;
        journal("pause %u ms", ms);
        if (attendre_avec_flux(l, (long)ms) < 0)
            return -1;
        return 1;
    }
    if (strcmp(jeton, "ping") == 0) {
        journal("PING envoyé");
        return envoyer_trame(l->fd, TRAMES_MIDI_TYPE_PING, 0, NULL, 0);
    }
invalide:
    fprintf(stderr, "faux_assistant : jeton de séquence invalide « %s »\n",
            jeton);
    return -2;
}

static int jouer_sequence(struct lecture *l, const char *sequence)
{
    if (sequence == NULL || sequence[0] == '\0')
        return 0;
    char *copie = strdup(sequence);
    if (copie == NULL)
        return -1;
    char *sauvegarde = NULL;
    for (char *jeton = strtok_r(copie, ",", &sauvegarde); jeton != NULL;
         jeton = strtok_r(NULL, ",", &sauvegarde)) {
        if (arret)
            break;
        const int r = jouer_jeton(l, jeton);
        if (r < 0) {
            free(copie);
            return r == -2 ? -2 : -1;
        }
    }
    free(copie);
    return 0;
}

/* Une session complète avec un client organum. Renvoie 0 pour continuer à
   écouter, 1 pour sortir (--tomber-apres), -1 pour une erreur de session. */
static int servir_client(int fd, const char *sequence, long tomber_apres,
                         int refuser_version)
{
    struct lecture l;
    memset(&l, 0, sizeof l);
    l.fd = fd;
    trame_decodeur_init(&l.decodeur, MAX_FRAME);

    uint8_t poignee[TRAMES_MIDI_POIGNEE_TAILLE];
    const int lu = lire_exact(fd, poignee, sizeof poignee, DELAI_POIGNEE);
    if (lu != 0) {
        fprintf(stderr, "faux_assistant : poignée %s\n",
                lu == -2 ? "non reçue dans le délai" : "interrompue");
        return -1;
    }

    struct poignee_vue vue;
    const int code = poignee_decoder(poignee, &vue);
    uint8_t reponse[TRAMES_MIDI_POIGNEE_TAILLE];
    if (code != 1 || refuser_version) {
        const uint8_t statut = code == -2 || refuser_version
                                   ? TRAMES_MIDI_STATUT_VERSION
                                   : TRAMES_MIDI_STATUT_INTERNE;
        poignee_encoder(reponse, statut, MAX_FRAME);
        ecrire_tout(fd, reponse, sizeof reponse);
        journal("poignée refusée (code %d, statut envoyé %u)", code, statut);
        return 0;
    }

    journal("poignée acceptée (client version %u, max_frame %u)", vue.version,
            vue.max_frame);
    poignee_encoder(reponse, TRAMES_MIDI_STATUT_OK, MAX_FRAME);
    if (ecrire_tout(fd, reponse, sizeof reponse) < 0)
        return -1;
    if (envoyer_device_list(fd) < 0)
        return -1;
    journal("DEVICE_LIST envoyée (2 claviers)");

    const int r = jouer_sequence(&l, sequence);
    if (r < 0)
        return r == -2 ? -2 : -1;

    if (tomber_apres >= 0) {
        journal("chute demandée dans %ld ms", tomber_apres);
        if (attendre_avec_flux(&l, tomber_apres) < 0)
            return -1;
        return 1;
    }

    /* Rester connecté et répondre aux contrôles jusqu'à la fermeture. */
    while (!arret) {
        if (pomper(&l, 1000) < 0)
            break;
    }
    return 0;
}

static int ouvrir_ecoute(const char *chemin)
{
    /* Sonde la socket comme le prescrit le protocole : un assistant vivant
       garde la sienne, une socket périmée est remplacée. */
    struct sockaddr_un adresse;
    memset(&adresse, 0, sizeof adresse);
    adresse.sun_family = AF_UNIX;
    memcpy(adresse.sun_path, chemin, strlen(chemin) + 1);

    const int sonde = socket(AF_UNIX, SOCK_STREAM, 0);
    if (sonde < 0) {
        perror("faux_assistant : socket");
        return -1;
    }
    if (connect(sonde, (struct sockaddr *)&adresse, sizeof adresse) == 0) {
        close(sonde);
        fprintf(stderr,
                "faux_assistant : un autre assistant écoute déjà sur %s\n",
                chemin);
        return -3;
    }
    const int erreur = errno;
    close(sonde);
    if (erreur != ENOENT && erreur != ECONNREFUSED) {
        fprintf(stderr, "faux_assistant : sonde de %s : %s\n", chemin,
                strerror(erreur));
        return -1;
    }

    umask(077);
    if (unlink(chemin) < 0 && errno != ENOENT) {
        perror("faux_assistant : unlink");
        return -1;
    }

    const int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        perror("faux_assistant : socket");
        return -1;
    }
    if (bind(fd, (struct sockaddr *)&adresse, sizeof adresse) < 0) {
        perror("faux_assistant : bind");
        close(fd);
        return -1;
    }
    if (chmod(chemin, 0600) < 0)
        perror("faux_assistant : chmod");
    if (listen(fd, 4) < 0) {
        perror("faux_assistant : listen");
        close(fd);
        unlink(chemin);
        return -1;
    }
    return fd;
}

static int attendre_client(int fd, long echeance)
{
    for (;;) {
        if (arret)
            return -1;
        long reste = echeance - maintenant_ms();
        if (reste < 0)
            return 0; /* délai écoulé sans client */
        struct pollfd p = {fd, POLLIN, 0};
        const int r = poll(&p, 1, (int)reste);
        if (r < 0) {
            if (errno == EINTR)
                continue;
            return -1;
        }
        if (r == 0)
            return 0;
        return 1;
    }
}

static void aide(const char *programme)
{
    printf("Usage : %s [--socket CHEMIN] [--sequence SÉQUENCE]\n"
           "       [--tomber-apres MS] [--refuser-version] "
           "[--attendre-client MS]\n",
           programme);
}

int main(int argc, char **argv)
{
    const char *socket_arg = NULL;
    const char *sequence = "";
    long tomber_apres = -1;
    long attendre = ATTENTE_CLIENT_DEFAUT;
    int refuser_version = 0;

    for (int i = 1; i < argc; ++i) {
        if (strcmp(argv[i], "--socket") == 0 && i + 1 < argc) {
            socket_arg = argv[++i];
        } else if (strcmp(argv[i], "--sequence") == 0 && i + 1 < argc) {
            sequence = argv[++i];
        } else if (strcmp(argv[i], "--tomber-apres") == 0 && i + 1 < argc) {
            tomber_apres = strtol(argv[++i], NULL, 10);
            if (tomber_apres < 0) {
                fprintf(stderr, "faux_assistant : --tomber-apres invalide\n");
                return 2;
            }
        } else if (strcmp(argv[i], "--refuser-version") == 0) {
            refuser_version = 1;
        } else if (strcmp(argv[i], "--attendre-client") == 0 && i + 1 < argc) {
            attendre = strtol(argv[++i], NULL, 10);
            if (attendre < 0) {
                fprintf(stderr,
                        "faux_assistant : --attendre-client invalide\n");
                return 2;
            }
        } else if (strcmp(argv[i], "--aide") == 0 ||
                   strcmp(argv[i], "-h") == 0) {
            aide(argv[0]);
            return 0;
        } else {
            fprintf(stderr, "faux_assistant : argument inconnu « %s »\n",
                    argv[i]);
            aide(argv[0]);
            return 2;
        }
    }

    char chemin[TRAMES_MIDI_SUN_PATH_MAX];
    if (socket_arg != NULL) {
        if (socket_arg[0] == '\0' ||
            strlen(socket_arg) >= sizeof chemin) {
            fprintf(stderr, "faux_assistant : chemin --socket invalide\n");
            return 2;
        }
        strcpy(chemin, socket_arg);
    } else if (trame_chemin_socket(getenv("ORGANUM_MIDI_SOCKET"),
                                   getenv("TMPDIR"), (unsigned long)getuid(),
                                   chemin, sizeof chemin) != 0) {
        fprintf(stderr, "faux_assistant : chemin de socket par défaut "
                        "invalide\n");
        return 2;
    }

    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = sur_signal;
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);

    const int ecoute = ouvrir_ecoute(chemin);
    if (ecoute < 0)
        return ecoute == -3 ? 3 : 1;
    journal("écoute sur %s", chemin);

    const long echeance = maintenant_ms() + attendre;
    int client_recu = 0;
    int code_sortie = 0;
    while (!arret) {
        int pret;
        if (!client_recu) {
            pret = attendre_client(ecoute, echeance);
            if (pret == 0) {
                fprintf(stderr,
                        "faux_assistant : aucun client avant %ld ms\n",
                        attendre);
                code_sortie = 4;
                break;
            }
        } else {
            struct pollfd p = {ecoute, POLLIN, 0};
            pret = poll(&p, 1, 1000);
            if (pret < 0) {
                if (errno == EINTR)
                    continue;
                code_sortie = 1;
                break;
            }
            if (pret == 0)
                continue;
        }
        if (pret < 0) {
            code_sortie = 1;
            break;
        }

        const int fd = accept(ecoute, NULL, NULL);
        if (fd < 0) {
            if (errno == EINTR)
                continue;
            perror("faux_assistant : accept");
            code_sortie = 1;
            break;
        }
        journal("client connecté");
        client_recu = 1;
        const int r = servir_client(fd, sequence, tomber_apres,
                                    refuser_version);
        close(fd);
        if (r == 1) {
            journal("connexion fermée par --tomber-apres");
            break;
        }
        if (r == -2) {
            code_sortie = 2;
            break;
        }
    }

    close(ecoute);
    unlink(chemin);
    journal("arrêt");
    return code_sortie;
}
