/* Entrée MIDI Windows par WinMM (midiIn), chargé avec cosmo_dlopen.
 *
 * WinMM n'a pas de port virtuel : on ouvre directement les périphériques
 * d'entrée (claviers USB, ou loopMIDI pour un clavier logiciel). Les
 * messages arrivent par une fonction de rappel, appelée dans un fil de
 * Windows inconnu de cosmopolitan : elle ne fait que déposer le message
 * dans une file circulaire sans verrou, que midi_lire() vide. */
#include <cosmo.h>
#include <dlfcn.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "../backends.h"

#define WINAPI __attribute__((__ms_abi__))
#define CALLBACK_FUNCTION 0x00030000u
#define MIM_DATA 0x3C3
#define MAX_ENTREES 16
#define TAILLE_FILE 1024  // puissance de deux

static uint32_t(WINAPI *pNumDevs)(void);
static uint32_t(WINAPI *pOpen)(void **, uint32_t, uintptr_t, uintptr_t, uint32_t);
static uint32_t(WINAPI *pStart)(void *);
static uint32_t(WINAPI *pStop)(void *);
static uint32_t(WINAPI *pClose)(void *);

struct midi {
  void *entrees[MAX_ENTREES];
  int nentrees, automatique;
  uint32_t vus;  // nombre de périphériques au dernier examen
  atomic_uint tete, queue;
  uint32_t file[TAILLE_FILE];
};

static int charger(void) {
  static int essaye, ok;
  if (essaye) return ok;
  essaye = 1;
  void *dll = cosmo_dlopen("winmm.dll", RTLD_NOW);
  if (!dll) return 0;
  pNumDevs = cosmo_dlsym(dll, "midiInGetNumDevs");
  pOpen = cosmo_dlsym(dll, "midiInOpen");
  pStart = cosmo_dlsym(dll, "midiInStart");
  pStop = cosmo_dlsym(dll, "midiInStop");
  pClose = cosmo_dlsym(dll, "midiInClose");
  return ok = pNumDevs && pOpen && pStart && pStop && pClose;
}

// Appelée par WinMM dans son propre fil : aucun appel à la libc.
__attribute__((__no_instrument_function__)) static void WINAPI
rappel(void *h, uint32_t msg, uintptr_t instance, uintptr_t p1, uintptr_t p2) {
  (void)h, (void)p2;
  if (msg != MIM_DATA) return;
  midi_t *m = (midi_t *)instance;
  unsigned t = atomic_load_explicit(&m->tete, memory_order_relaxed);
  if (t - atomic_load_explicit(&m->queue, memory_order_acquire) >= TAILLE_FILE)
    return;  // file pleine : message perdu plutôt que bloquer
  m->file[t & (TAILLE_FILE - 1)] = (uint32_t)p1;
  atomic_store_explicit(&m->tete, t + 1, memory_order_release);
}

midi_t *winmm_midi_ouvrir(const char *nom_client, const char *nom_port) {
  (void)nom_client, (void)nom_port;
  if (!charger()) return NULL;
  return calloc(1, sizeof(midi_t));
}

int winmm_midi_fd(midi_t *m) { (void)m; return -1; }

int winmm_midi_adresse(midi_t *m, int *client, int *port) {
  (void)m;
  if (client) *client = -1;
  if (port) *port = -1;
  return 0;
}

// « client » : numéro du périphérique d'entrée WinMM ; « port » ignoré.
int winmm_midi_connecter_depuis(midi_t *m, int client, int port) {
  (void)port;
  if (!m || m->nentrees >= MAX_ENTREES) return -1;
  void *h;
  if (pOpen(&h, client, (uintptr_t)rappel, (uintptr_t)m, CALLBACK_FUNCTION)) return -1;
  pStart(h);
  m->entrees[m->nentrees++] = h;
  return 0;
}

static void fermer_entrees(midi_t *m) {
  for (int i = 0; i < m->nentrees; ++i) {
    pStop(m->entrees[i]);
    pClose(m->entrees[i]);
  }
  m->nentrees = 0;
}

static int ouvrir_tout(midi_t *m) {
  int n = 0;
  m->vus = pNumDevs();
  for (uint32_t i = 0; i < m->vus; ++i) n += winmm_midi_connecter_depuis(m, i, 0) == 0;
  return n;
}

int winmm_midi_connecter_tout(midi_t *m) {
  if (!m) return -1;
  m->automatique = 1;
  return ouvrir_tout(m);
}

int winmm_midi_lire(midi_t *m, midi_msg_t *msgs, int max) {
  if (!m) return -1;
  // Branchement ou retrait d'un clavier : on rouvre tout (examen peu
  // coûteux, une fois toutes les 256 lectures environ).
  static unsigned compte;
  if (m->automatique && (++compte & 255) == 0 && pNumDevs() != m->vus) {
    fermer_entrees(m);
    ouvrir_tout(m);
  }
  int n = 0;
  unsigned q = atomic_load_explicit(&m->queue, memory_order_relaxed);
  unsigned t = atomic_load_explicit(&m->tete, memory_order_acquire);
  for (; q != t && n < max; ++q) {
    uint32_t v = m->file[q & (TAILLE_FILE - 1)];
    unsigned char statut = v & 0xFF, d1 = (v >> 8) & 0x7F, d2 = (v >> 16) & 0x7F;
    switch (statut & 0xF0) {
      case 0x90:
        if (d2 == 0) statut = 0x80 | (statut & 0x0F);  // note on vélocité 0
        // fallthrough
      case 0x80:
      case 0xB0:
      case 0xC0:
        msgs[n++] = (midi_msg_t){statut, d1, d2};
    }
  }
  atomic_store_explicit(&m->queue, q, memory_order_release);
  return n;
}

void winmm_midi_fermer(midi_t *m) {
  if (!m) return;
  fermer_entrees(m);
  free(m);
}
