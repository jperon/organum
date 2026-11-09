// Anneau audio partagé (plateforme/macos/anneau_audio.h) : disposition de
// l'en-tête, bornes de capacité, compteurs, arrêt, et transport SPSC réel
// entre deux threads avec vérification de l'ordre des échantillons après
// bouclage.
#define _GNU_SOURCE

#include "../macos/anneau_audio.h"

#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

_Static_assert(offsetof(struct anneau_entete, magie) == 0,
               "magie doit commencer l'en-tête");
_Static_assert(offsetof(struct anneau_entete, drapeaux) == 32,
               "drapeaux attendu à l'offset 32");
_Static_assert(offsetof(struct anneau_entete, ecrit) == 64,
               "ecrit doit ouvrir la ligne des compteurs");
_Static_assert(offsetof(struct anneau_entete, lu) == 72, "lu attendu à 72");
_Static_assert(offsetof(struct anneau_entete, arret) == 104,
               "arret attendu à 104");
_Static_assert(offsetof(struct anneau_entete, demarre) == 108,
               "demarre attendu à 108");
_Static_assert(sizeof(struct anneau_entete) == 128,
               "en-tête arrondi à 128 octets");
_Static_assert(ANNEAU_AUDIO_CAPACITE_MAX * 2u * sizeof(float) == 128u * 1024u,
               "capacité maximale = 128 Kio en float32 stéréo");

static int echecs;

static void verifier(int condition, const char *message) {
  if (!condition) {
    printf("ÉCHEC : %s\n", message);
    ++echecs;
  }
}

static struct anneau_entete *allouer(uint32_t capacite) {
  const size_t taille =
      sizeof(struct anneau_entete) + (size_t)capacite * 8u;
  struct anneau_entete *e = malloc(taille);
  if (e == NULL) return NULL;
  if (anneau_initialiser(e, 2, 8, 48000, 64, capacite, 1) != 0) {
    free(e);
    return NULL;
  }
  return e;
}

static uint32_t motif_impair(uint32_t valeur) { return valeur ^ 0xA5A5A5A5u; }

static void remplir_source(uint32_t *source, size_t debut, size_t n) {
  for (size_t j = 0; j < n; ++j) {
    const uint32_t v = (uint32_t)(debut + j);
    source[2 * j] = v;
    source[2 * j + 1] = motif_impair(v);
  }
}

// Vérifie que les trames de destination portent bien les indices attendus.
static int verifier_destination(const uint32_t *destination, size_t debut,
                                size_t n) {
  for (size_t j = 0; j < n; ++j) {
    const uint32_t v = (uint32_t)(debut + j);
    if (destination[2 * j] != v ||
        destination[2 * j + 1] != motif_impair(v))
      return 0;
  }
  return 1;
}

static void tester_bornes(void) {
  struct anneau_entete *e = allouer(256);
  if (e == NULL) {
    verifier(0, "bornes : allocation");
    return;
  }
  uint32_t source[256 * 2];
  uint32_t destination[256 * 2];
  remplir_source(source, 0, 256);

  verifier(e->magie == ANNEAU_AUDIO_MAGIE &&
               e->version == ANNEAU_AUDIO_VERSION,
           "en-tête : magie et version courantes");
  verifier(anneau_place_libre(e) == 256, "bornes : anneau vide");
  verifier(anneau_disponible(e) == 0, "bornes : rien à lire");
  verifier(atomic_load(&e->demarre) == 0, "démarrage : drapeau à zéro");
  verifier(anneau_lire(e, destination, 1) == 0,
           "démarrage : lecture vide refusée");
  verifier(atomic_load(&e->underruns) == 0,
           "démarrage : pas d'underrun avant la première écriture");

  verifier(anneau_ecrire(e, source, 200) == 200, "bornes : écriture de 200");
  verifier(atomic_load(&e->demarre) == 1,
           "démarrage : drapeau posé à la première écriture");
  verifier(anneau_place_libre(e) == 56, "bornes : 56 trames libres");
  verifier(anneau_disponible(e) == 200, "bornes : 200 trames disponibles");

  const uint64_t libre = anneau_place_libre(e);
  const size_t ecrites = anneau_ecrire(e, source, 100);
  verifier(ecrites == 56, "bornes : écriture plafonnée à la place libre");
  verifier((uint64_t)ecrites <= libre,
           "bornes : l'écriture ne dépasse jamais la place libre");
  verifier(atomic_load(&e->overruns) == 44,
           "bornes : 44 trames refusées comptées en overruns");
  verifier(anneau_place_libre(e) == 0, "bornes : anneau plein");
  verifier(anneau_ecrire(e, source, 1) == 0, "bornes : plein, rien écrit");
  verifier(atomic_load(&e->overruns) == 45, "bornes : overrun de saturation");

  verifier(anneau_lire(e, destination, 256) == 256,
           "bornes : lecture de tout l'anneau");
  verifier(verifier_destination(destination, 0, 200),
           "bornes : premières 200 trames dans l'ordre");
  verifier(verifier_destination(destination + 200 * 2, 0, 56),
           "bornes : secondes 56 trames dans l'ordre après bouclage");
  verifier(atomic_load(&e->trames_jouees) == 256,
           "bornes : trames_jouees comptées");

  verifier(anneau_lire(e, destination, 1) == 0, "bornes : vide, rien lu");
  verifier(atomic_load(&e->underruns) == 1, "bornes : underrun compté");

  anneau_reinitialiser(e);
  verifier(atomic_load(&e->ecrit) == 0 && atomic_load(&e->lu) == 0 &&
               atomic_load(&e->underruns) == 0 &&
               atomic_load(&e->overruns) == 0 &&
               atomic_load(&e->trames_jouees) == 0 &&
               atomic_load(&e->arret) == 0 && atomic_load(&e->demarre) == 0,
           "bornes : réinitialisation des compteurs");
  verifier(anneau_place_libre(e) == 256, "bornes : libre après remise à zéro");
  verifier(anneau_lire(e, destination, 1) == 0 &&
               atomic_load(&e->underruns) == 0,
           "redémarrage : lecture vide sans underrun après remise à zéro");

  verifier(anneau_capacite_negocier(512, 3) == 2048,
           "capacité négociée : 3 périodes de 512 → 2048 trames");
  verifier(anneau_capacite_negocier(512, 1) == 512,
           "capacité négociée : une période garde sa taille");
  verifier(anneau_capacite_negocier(128, 1) == ANNEAU_AUDIO_CAPACITE_MIN,
           "capacité négociée : jamais sous le minimum");
  verifier(anneau_capacite_negocier(512, 64) == ANNEAU_AUDIO_CAPACITE_MAX,
           "capacité négociée : jamais au-dessus du maximum");

  atomic_store(&e->arret, 1);
  verifier(anneau_ecrire(e, source, 1) == 0, "arrêt : écriture refusée");
  verifier(atomic_load(&e->ecrit) == 0, "arrêt : ecrit inchangé");
  verifier(anneau_lire(e, destination, 1) == 0, "arrêt : lecture refusée");
  verifier(atomic_load(&e->lu) == 0, "arrêt : lu inchangé");
  atomic_store(&e->arret, 0);
  verifier(anneau_ecrire(e, source, 1) == 1, "arrêt : reprise après acquittement");
  anneau_reinitialiser(e);

  verifier(anneau_initialiser(e, 2, 8, 48000, 64, 100, 0) == -1,
           "capacité : 100 n'est pas une puissance de deux");
  verifier(anneau_initialiser(e, 2, 8, 48000, 64,
                              ANNEAU_AUDIO_CAPACITE_MIN - 1, 0) == -1,
           "capacité : sous le minimum refusée");
  verifier(anneau_initialiser(e, 2, 8, 48000, 64,
                              ANNEAU_AUDIO_CAPACITE_MAX * 2, 0) == -1,
           "capacité : au-dessus du maximum refusée");
  verifier(anneau_initialiser(e, 0, 8, 48000, 64, 256, 0) == -1,
           "capacité : zéro canal refusé");
  verifier(anneau_initialiser(e, 2, 0, 48000, 64, 256, 0) == -1,
           "capacité : trame vide refusée");
  verifier(anneau_initialiser(e, 2, 8, 48000, 64,
                              ANNEAU_AUDIO_CAPACITE_MAX, 0) == 0,
           "capacité : maximum accepté");

  free(e);
}

struct contexte {
  struct anneau_entete *e;
  atomic_int *fini;
  atomic_int *erreur;
  size_t total;
};

static void *producteur(void *arg) {
  struct contexte *c = arg;
  uint32_t source[2048 * 2];
  const size_t tailles[3] = {1, 7, c->e->periode};
  size_t ecrites = 0;
  size_t etape = 0;

  while (ecrites < c->total) {
    size_t demande = tailles[etape++ % 3];
    if (demande > c->total - ecrites) demande = c->total - ecrites;
    remplir_source(source, ecrites, demande);
    const size_t n = anneau_ecrire(c->e, source, demande);
    ecrites += n;
    if (n == 0) sched_yield();
  }
  atomic_store(c->fini, 1);
  return NULL;
}

static void *consommateur(void *arg) {
  struct contexte *c = arg;
  uint32_t destination[2048 * 2];
  const size_t tailles[3] = {1, 7, c->e->periode};
  size_t lues = 0;
  size_t etape = 0;

  while (lues < c->total) {
    size_t demande = tailles[etape++ % 3];
    if (demande > c->total - lues) demande = c->total - lues;
    const size_t n = anneau_lire(c->e, destination, demande);
    if (!verifier_destination(destination, lues, n)) {
      atomic_store(c->erreur, 1);
      return NULL;
    }
    lues += n;
    if (n == 0) {
      sched_yield();
      if (atomic_load(c->fini) != 0 && anneau_disponible(c->e) == 0) break;
    }
  }
  if (lues != c->total) atomic_store(c->erreur, 1);
  return NULL;
}

static void tester_threads(uint32_t capacite) {
  struct anneau_entete *e = allouer(capacite);
  if (e == NULL) {
    verifier(0, "threads : allocation");
    return;
  }
  atomic_int fini = 0;
  atomic_int erreur = 0;
  struct contexte c = {e, &fini, &erreur, 1000000u};

  pthread_t tp;
  pthread_t tc;
  verifier(pthread_create(&tp, NULL, producteur, &c) == 0,
           "threads : création du producteur");
  verifier(pthread_create(&tc, NULL, consommateur, &c) == 0,
           "threads : création du consommateur");
  pthread_join(tp, NULL);
  pthread_join(tc, NULL);

  verifier(atomic_load(&erreur) == 0,
           "threads : ordre des échantillons préservé après bouclage");
  verifier(atomic_load(&e->ecrit) == c.total,
           "threads : total des trames écrites");
  verifier(atomic_load(&e->lu) == c.total, "threads : total des trames lues");
  verifier(atomic_load(&e->trames_jouees) == c.total,
           "threads : compteur trames_jouees");
  verifier(anneau_disponible(e) == 0, "threads : anneau vidé");
  verifier(anneau_place_libre(e) == capacite, "threads : anneau entièrement libre");

  // Les compteurs d'incidents restent cohérents (64 bits) ; leur valeur
  // exacte dépend de l'ordonnancement, elle est vérifiée dans tester_bornes.
  printf("  capacité %u : overruns=%llu underruns=%llu\n", capacite,
         (unsigned long long)atomic_load(&e->overruns),
         (unsigned long long)atomic_load(&e->underruns));

  free(e);
}

int main(void) {
  tester_bornes();
  tester_threads(256);
  tester_threads(512);
  tester_threads(2048);

  if (echecs == 0) {
    printf("-- anneau audio : OK\n");
    return 0;
  }
  printf("-- anneau audio : %d échec(s)\n", echecs);
  return 1;
}
