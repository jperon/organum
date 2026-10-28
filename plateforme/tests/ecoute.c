#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <poll.h>
#include <time.h>

#include "../midi.h"

int main(int argc, char **argv)
{
    int seconds = 10;
    if (argc >= 2) {
        seconds = atoi(argv[1]);
        if (seconds <= 0) {
            seconds = 10;
        }
    }

    midi_t *midi = midi_ouvrir("Orgue-test", "entree");
    if (midi == NULL) {
        fprintf(stderr, "Erreur: impossible d'ouvrir le port MIDI\n");
        return 1;
    }

    int c = -1, p = -1;
    if (midi_adresse(midi, &c, &p) == 0) {
        printf("Port MIDI créé: %d:%d\n", c, p);
        fflush(stdout);
    } else {
        printf("Port MIDI créé\n");
        fflush(stdout);
    }

    time_t end = time(NULL) + seconds;
    while (time(NULL) < end) {
        int fd = midi_fd(midi);
        if (fd < 0) {
            break;
        }
        time_t now = time(NULL);
        int remaining = (int)(end - now);
        if (remaining < 0) {
            break;
        }
        struct pollfd pfd;
        pfd.fd = fd;
        pfd.events = POLLIN;
        pfd.revents = 0;
        int pr = poll(&pfd, 1, remaining * 1000);
        if (pr <= 0) {
            if (pr == 0) {
                break; /* timeout */
            }
            break;
        }
        if (pfd.revents & POLLIN) {
            midi_msg_t msgs[64];
            int n = midi_lire(midi, msgs, 64);
            for (int i = 0; i < n; i++) {
                printf("%02x %02x %02x\n", msgs[i].statut & 0xFF, msgs[i].d1 & 0xFF, msgs[i].d2 & 0xFF);
                fflush(stdout);
            }
        }
    }

    midi_fermer(midi);
    return 0;
}
