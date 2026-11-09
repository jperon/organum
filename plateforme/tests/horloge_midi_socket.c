/* Vérifie que les reculs de reconnexion MIDI se mesurent en temps mural.
 *
 * Sous XNU x86-64, cosmocc reconstitue CLOCK_MONOTONIC depuis le TSC avec un
 * diviseur supposant 3 GHz : sur une VM à 0,88 GHz, il avance à ~0,29 × le
 * temps réel. Le backend socket doit donc employer CLOCK_REALTIME sous XNU
 * pour ses durées « humaines ». Le test inclut directement midi_socket.c et
 * remplace clock_gettime par une horloge simulée : CLOCK_REALTIME avance au
 * temps mural, CLOCK_MONOTONIC au tiers de sa vitesse. Sans le correctif, le
 * recul d'une seconde durerait ainsi plus de trois secondes.
 *
 * Compilation (voir scripts/tests-unitaires.sh) :
 *   gcc -I <dossier contenant un cosmo.h vide> ...
 */
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

/* Horloge simulée : le temps mural est la référence ; CLOCK_MONOTONIC est
   volontairement trois fois trop lent, comme le TSC mal divisé de XNU. */
static long long faux_reel_ns = 1700000000LL * 1000000000LL;
static long long faux_mono_ns = 5000LL * 1000000000LL;

static int fausse_clock_gettime(clockid_t id, struct timespec *t)
{
    const long long v = id == CLOCK_MONOTONIC ? faux_mono_ns : faux_reel_ns;
    t->tv_sec = (time_t)(v / 1000000000LL);
    t->tv_nsec = (long)(v % 1000000000LL);
    return 0;
}

/* Avance le temps mural de millisecondes, et CLOCK_MONOTONIC d'un tiers. */
static void avancer_mural(long long ms)
{
    faux_reel_ns += ms * 1000000LL;
    faux_mono_ns += ms * 1000000LL / 3;
}

#define clock_gettime fausse_clock_gettime
#define IsXnu() 1
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
    midi_t m;
    memset(&m, 0, sizeof m);

    /* 1 s sur CLOCK_REALTIME : la valeur enregistrée doit être le temps mural
       courant + 1 s, pas l'horloge monotone faussée. */
    armer_recul(&m, MIDI_SOCKET_DELAI);
    verifier(m.prochain_essai.tv_sec ==
                 (time_t)(faux_reel_ns / 1000000000LL) + MIDI_SOCKET_DELAI,
             "XNU : le recul est armé sur CLOCK_REALTIME");
    verifier(!echeance_atteinte(&m), "le recul d'une seconde n'est pas encore échu");

    /* 1,05 s de temps mural : l'échéance est atteinte même si CLOCK_MONOTONIC
       n'a avancé que de 0,35 s. */
    avancer_mural(1050);
    verifier(echeance_atteinte(&m),
             "une seconde murale suffit malgré CLOCK_MONOTONIC trop lent");

    /* Saut d'horloge vers l'arrière : l'échéance ne doit pas être repoussée de
       trente secondes ; une tentative immédiate réarme ensuite proprement. */
    armer_recul(&m, MIDI_SOCKET_DELAI);
    faux_reel_ns -= 30000000000LL;
    faux_mono_ns -= 30000000000LL;
    verifier(echeance_atteinte(&m),
             "un saut d'horloge vers l'arrière ne bloque pas la reconnexion");

    armer_recul(&m, MIDI_SOCKET_DELAI_VERSION);
    verifier(!echeance_atteinte(&m),
             "après le saut, le refus de version réarme un recul de 10 s");
    avancer_mural((MIDI_SOCKET_DELAI_VERSION + 1) * 1000LL);
    verifier(echeance_atteinte(&m),
             "le recul de 10 s n'est pas converti en attente démesurée");

    if (echecs != 0)
        printf("%d échec(s)\n", echecs);
    return echecs == 0 ? 0 : 1;
}
