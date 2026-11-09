/* Vérifie que seul le processus créateur lit la socket MIDI.
 *
 * Redbean sert chaque requête HTTP dans un fils : celui-ci hérite du
 * descripteur et de la structure partagée du backend socket. Si un fils
 * appelait midi_lire(), il consommerait une trame MIDI (perdue pour le fil
 * audio) et répondrait aussi aux PING (deux PONG pour un PING). Le backend
 * mémorise donc le PID créateur et refuse de lire ailleurs.
 *
 * Le test inclut directement midi_socket.c pour rester proche du code réel :
 * un couple de sockets AF_UNIX contient une Note On, un fils essaie de la
 * lire (il doit obtenir 0 et laisser la trame), puis le père la lit (il doit
 * obtenir exactement cette note). Compilation hôte avec un cosmo.h vide.
 *
 * Compilation (voir scripts/tests-unitaires.sh) :
 *   gcc -I <dossier contenant un cosmo.h vide> ...
 */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

#include "../macos/midi_socket.c"

static int echecs;

static void verifier(int condition, const char *message)
{
    if (condition) {
        printf("OK    : %s\n", message);
    } else {
        printf("ÉCHEC : %s\n", message);
        ++echecs;
    }
}

int main(void)
{
    int sv[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) < 0) {
        perror("socketpair");
        return 2;
    }

    midi_t *m = calloc(1, sizeof(*m));
    if (m == NULL)
        return 2;
    m->fd = sv[0];
    m->etat = ETAT_CONNECTE;
    m->createur = getpid();
    m->partage = 0;
    m->max_frame = MIDI_SOCKET_MAX_FRAME;
    trame_decodeur_init(&m->decodeur, MIDI_SOCKET_MAX_FRAME);

    const uint8_t corps[3] = {0x90, 60, 100};
    uint8_t trame[TRAMES_MIDI_ENTETE_TAILLE + 3];
    const int taille = trame_encoder(trame, sizeof trame, TRAMES_MIDI_TYPE_MIDI,
                                     0, corps, 3);
    if (taille < 0 || write(sv[1], trame, (size_t)taille) != taille)
        return 2;
    /* Fin d'écriture : le père lira la note puis EOF sans bloquer. */
    close(sv[1]);
    sv[1] = -1;

    pid_t pid = fork();
    if (pid < 0) {
        perror("fork");
        return 2;
    }
    if (pid == 0) {
        /* Le fils hérite de createur = PID du père : il ne doit rien lire. */
        midi_msg_t msgs[8];
        const int n = midi_socket_midi_lire(m, msgs, 8);
        _exit(n == 0 ? 0 : 1);
    }

    int statut = 0;
    if (waitpid(pid, &statut, 0) != pid)
        return 2;
    verifier(WIFEXITED(statut) && WEXITSTATUS(statut) == 0,
             "un fils de requête ne consomme aucune trame MIDI");

    midi_msg_t msgs[8];
    const int n = midi_socket_midi_lire(m, msgs, 8);
    verifier(n == 1 && msgs[0].statut == 0x90 && msgs[0].d1 == 60 &&
                 msgs[0].d2 == 100,
             "le processus créateur lit la note laissée par le fils");

    free(m);
    close(sv[0]);
    return echecs == 0 ? 0 : 1;
}
