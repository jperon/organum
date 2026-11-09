/* Aiguillage de audio.h vers l'implémentation du système hôte. */
#include <cosmo.h>
#include <stdlib.h>
#include "backends.h"

/* ORGANUM_AUDIO_SOCKET force le backend socket sous Linux, comme
   ORGANUM_MIDI_SOCKET le fait pour le MIDI. Le résultat est mémorisé :
   audio_ecrire() est appelée dans le fil audio, qui ne doit pas faire de
   getenv à chaque tour. Sous Windows, l'aiguillage garde toujours WinMM. */
static int audio_socket_imposee_interne(void)
{
    static int calcule, valeur;
    if (!calcule) {
        const char *chemin = getenv("ORGANUM_AUDIO_SOCKET");
        valeur = chemin != NULL && chemin[0] != '\0';
        calcule = 1;
    }
    return valeur;
}

#define AIGUILLER_AUDIO(f, ...)                                               \
    (IsWindows()                                                              \
         ? winmm_##f(__VA_ARGS__)                                             \
         : (IsXnu() || audio_socket_imposee_interne()) ? audio_socket_##f(__VA_ARGS__)      \
                                         : alsa_##f(__VA_ARGS__))

audio_t *audio_ouvrir(const char *p, int taux, int canaux, int periode, int nb)
{ return AIGUILLER_AUDIO(audio_ouvrir, p, taux, canaux, periode, nb); }
int audio_ecrire(audio_t *a, const float *e, int n) { return AIGUILLER_AUDIO(audio_ecrire, a, e, n); }
int audio_xruns(audio_t *a) { return AIGUILLER_AUDIO(audio_xruns, a); }
void audio_fermer(audio_t *a) { AIGUILLER_AUDIO(audio_fermer, a); }
const char *audio_chemin(audio_t *a) { return AIGUILLER_AUDIO(audio_chemin, a); }
const char *audio_format(audio_t *a) { return AIGUILLER_AUDIO(audio_format, a); }
const char *audio_derniere_erreur(void) { return AIGUILLER_AUDIO(audio_derniere_erreur); }
int audio_perdue(audio_t *a) { return AIGUILLER_AUDIO(audio_perdue, a); }
void audio_oublier_fils(void) { AIGUILLER_AUDIO(audio_oublier_fils); }
int audio_supportee(void) { return IsLinux() || IsWindows() || IsXnu(); }

/* Le backend socket est celui de XNU, ou un forçage Linux pour les tests ;
   jamais Windows, même si ORGANUM_AUDIO_SOCKET est posé. */
int audio_socket_actif(void)
{
    return !IsWindows() && (IsXnu() || audio_socket_imposee_interne());
}

int audio_socket_imposee(void) { return audio_socket_imposee_interne(); }

/* Interrogations propres au backend socket. Hors de lui, elles n'ont pas de
   sens : ne jamais appeler l'implémentation socket dans ce cas. */
int audio_connecte(audio_t *a)
{
    if (a == NULL || !audio_socket_actif())
        return 0;
    return audio_socket_audio_connecte(a);
}

uint64_t audio_trames_jouees(audio_t *a)
{
    if (a == NULL || !audio_socket_actif())
        return 0;
    return audio_socket_audio_trames_jouees(a);
}

int audio_chemin_assistant(audio_t *a, char *sortie, int capacite)
{
    if (a == NULL || sortie == NULL || capacite <= 0 || !audio_socket_actif())
        return -1;
    return audio_socket_audio_chemin_assistant(a, sortie, capacite);
}
