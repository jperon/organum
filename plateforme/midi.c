/* Aiguillage de midi.h vers l'implémentation du système hôte. */
#include <cosmo.h>
#include <stdlib.h>
#include "backends.h"

/* Sous Linux, un faux assistant peut parler le protocole macOS : la variable
   rend le backend testable sans machine Apple. Le résultat est mémorisé :
   midi_lire() est appelée dans le fil audio, qui ne doit pas faire de getenv
   à chaque tour. */
static int socket_imposee(void)
{
    static int calcule, valeur;
    if (!calcule) {
        const char *chemin = getenv("ORGANUM_MIDI_SOCKET");
        valeur = chemin != NULL && chemin[0] != '\0';
        calcule = 1;
    }
    return valeur;
}

#define AIGUILLER_MIDI(f, ...)                                                \
    (IsWindows()                                                              \
         ? winmm_##f(__VA_ARGS__)                                             \
         : (IsXnu() || socket_imposee()) ? midi_socket_##f(__VA_ARGS__)       \
                                         : alsa_##f(__VA_ARGS__))

midi_t *midi_ouvrir(const char *c, const char *p) { return AIGUILLER_MIDI(midi_ouvrir, c, p); }
int midi_fd(midi_t *m) { return AIGUILLER_MIDI(midi_fd, m); }
int midi_lire(midi_t *m, midi_msg_t *msgs, int max) { return AIGUILLER_MIDI(midi_lire, m, msgs, max); }
int midi_connecter_depuis(midi_t *m, int c, int p) { return AIGUILLER_MIDI(midi_connecter_depuis, m, c, p); }
int midi_adresse(midi_t *m, int *c, int *p) { return AIGUILLER_MIDI(midi_adresse, m, c, p); }
int midi_connecter_tout(midi_t *m) { return AIGUILLER_MIDI(midi_connecter_tout, m); }
int midi_ports(midi_t *m, struct midi_port *ports, int max) { return AIGUILLER_MIDI(midi_ports, m, ports, max); }
int midi_connecter(midi_t *m, int c, int p) { return AIGUILLER_MIDI(midi_connecter, m, c, p); }
int midi_deconnecter(midi_t *m, int c, int p) { return AIGUILLER_MIDI(midi_deconnecter, m, c, p); }
void midi_fermer(midi_t *m) { AIGUILLER_MIDI(midi_fermer, m); }
int midi_supportee(void) { return IsLinux() || IsWindows(); }
