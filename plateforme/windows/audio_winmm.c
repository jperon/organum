/* Sortie audio Windows par WinMM (waveOut), chargé avec cosmo_dlopen.
 *
 * Plusieurs tampons tournent dans la file de waveOut ; audio_ecrire()
 * remplit le premier tampon libre et attend, sur un événement que WinMM
 * signale à chaque tampon joué, quand tous sont occupés. Aucune fonction
 * de rappel : rien ne s'exécute dans un fil créé par Windows. */
#include <cosmo.h>
#include <dlfcn.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "libc/nt/events.h"
#include "libc/nt/runtime.h"
#include "libc/nt/synchronization.h"

#include "../backends.h"

#define WINAPI __attribute__((__ms_abi__))
#define WAVE_MAPPER 0xFFFFFFFFu
#define CALLBACK_EVENT 0x00050000u
#define WAVE_FORMAT_IEEE_FLOAT 3
#define WHDR_DONE 1u
#define MAX_TAMPONS 8

struct __attribute__((__packed__)) waveformatex {
  uint16_t wFormatTag, nChannels;
  uint32_t nSamplesPerSec, nAvgBytesPerSec;
  uint16_t nBlockAlign, wBitsPerSample, cbSize;
};

struct wavehdr {
  char *lpData;
  uint32_t dwBufferLength, dwBytesRecorded;
  uintptr_t dwUser;
  uint32_t dwFlags, dwLoops;
  struct wavehdr *lpNext;
  uintptr_t reserved;
};

static uint32_t(WINAPI *pOpen)(void **, uint32_t, const struct waveformatex *,
                               uintptr_t, uintptr_t, uint32_t);
static uint32_t(WINAPI *pPrepare)(void *, struct wavehdr *, uint32_t);
static uint32_t(WINAPI *pUnprepare)(void *, struct wavehdr *, uint32_t);
static uint32_t(WINAPI *pWrite)(void *, struct wavehdr *, uint32_t);
static uint32_t(WINAPI *pReset)(void *);
static uint32_t(WINAPI *pClose)(void *);

struct audio {
  void *sortie;
  int64_t evenement;
  int canaux, periode, ntampons, xruns;
  struct wavehdr tampons[MAX_TAMPONS];
  int en_file[MAX_TAMPONS];
};

static int charger(void) {
  static int essaye, ok;
  if (essaye) return ok;
  essaye = 1;
  void *dll = cosmo_dlopen("winmm.dll", RTLD_NOW);
  if (!dll) return 0;
  pOpen = cosmo_dlsym(dll, "waveOutOpen");
  pPrepare = cosmo_dlsym(dll, "waveOutPrepareHeader");
  pUnprepare = cosmo_dlsym(dll, "waveOutUnprepareHeader");
  pWrite = cosmo_dlsym(dll, "waveOutWrite");
  pReset = cosmo_dlsym(dll, "waveOutReset");
  pClose = cosmo_dlsym(dll, "waveOutClose");
  return ok = pOpen && pPrepare && pUnprepare && pWrite && pReset && pClose;
}

audio_t *winmm_audio_ouvrir(const char *peripherique, int taux, int canaux,
                            int periode, int nb_periodes) {
  (void)peripherique;  // toujours le périphérique par défaut (WAVE_MAPPER)
  if (!charger()) return NULL;
  audio_t *a = calloc(1, sizeof(*a));
  if (!a) return NULL;
  a->canaux = canaux;
  a->periode = periode;
  a->ntampons = nb_periodes < 2 ? 2 : nb_periodes > MAX_TAMPONS ? MAX_TAMPONS : nb_periodes;
  a->evenement = CreateEvent(NULL, false, false, NULL);

  struct waveformatex f = {
      .wFormatTag = WAVE_FORMAT_IEEE_FLOAT,
      .nChannels = canaux,
      .nSamplesPerSec = taux,
      .nAvgBytesPerSec = taux * canaux * 4,
      .nBlockAlign = canaux * 4,
      .wBitsPerSample = 32,
  };
  if (!a->evenement ||
      pOpen(&a->sortie, WAVE_MAPPER, &f, a->evenement, 0, CALLBACK_EVENT)) {
    if (a->evenement) CloseHandle(a->evenement);
    free(a);
    return NULL;
  }
  for (int i = 0; i < a->ntampons; ++i) {
    struct wavehdr *t = &a->tampons[i];
    t->dwBufferLength = periode * canaux * 4;
    t->lpData = calloc(1, t->dwBufferLength);
    pPrepare(a->sortie, t, sizeof(*t));
  }
  return a;
}

int winmm_audio_ecrire(audio_t *a, const float *entrelace, int trames) {
  if (!a || trames > a->periode) return -1;
  for (;;) {
    for (int i = 0; i < a->ntampons; ++i) {
      struct wavehdr *t = &a->tampons[i];
      if (a->en_file[i] && !(t->dwFlags & WHDR_DONE)) continue;
      // Tous les tampons joués d'un coup : la file s'est vidée.
      int libres = 0;
      for (int k = 0; k < a->ntampons; ++k)
        libres += !a->en_file[k] || (a->tampons[k].dwFlags & WHDR_DONE);
      if (libres == a->ntampons && a->en_file[i]) a->xruns++;
      memcpy(t->lpData, entrelace, trames * a->canaux * 4);
      t->dwBufferLength = trames * a->canaux * 4;
      t->dwFlags &= ~WHDR_DONE;
      if (pWrite(a->sortie, t, sizeof(*t))) return -1;
      a->en_file[i] = 1;
      return trames;
    }
    WaitForSingleObject(a->evenement, 1000);
  }
}

int winmm_audio_xruns(audio_t *a) { return a ? a->xruns : 0; }

void winmm_audio_fermer(audio_t *a) {
  if (!a) return;
  pReset(a->sortie);
  for (int i = 0; i < a->ntampons; ++i) {
    pUnprepare(a->sortie, &a->tampons[i], sizeof(a->tampons[i]));
    free(a->tampons[i].lpData);
  }
  pClose(a->sortie);
  CloseHandle(a->evenement);
  free(a);
}

const char *winmm_audio_chemin(audio_t *a) { (void)a; return "winmm"; }
const char *winmm_audio_format(audio_t *a) { (void)a; return "FLOAT_LE"; }
