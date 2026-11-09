// Anneau audio partagé après fork (plateforme/macos/anneau_audio.h) : la
// mémoire MAP_SHARED et les compteurs atomiques restent partagés, et une
// écriture dans le fils laisse l'anneau cohérent pour le père. Le hook
// d'oubli de l'anneau viendra à l'étape suivante ; ce test borne ce qui est
// déjà vérifiable : partage et cohérence des compteurs.
#define _GNU_SOURCE

#include "../macos/anneau_audio.h"

#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>

static int echecs;

static void verifier(int condition, const char *message) {
  if (!condition) {
    printf("ÉCHEC : %s\n", message);
    ++echecs;
  }
}

static void remplir(uint32_t *source, size_t debut, size_t n) {
  for (size_t j = 0; j < n; ++j) {
    source[2 * j] = (uint32_t)(debut + j);
    source[2 * j + 1] = (uint32_t)(debut + j) ^ 0xA5A5A5A5u;
  }
}

static int destination_valide(const uint32_t *destination, size_t debut,
                              size_t n) {
  for (size_t j = 0; j < n; ++j) {
    const uint32_t v = (uint32_t)(debut + j);
    if (destination[2 * j] != v ||
        destination[2 * j + 1] != (v ^ 0xA5A5A5A5u))
      return 0;
  }
  return 1;
}

int main(void) {
  const uint32_t capacite = 256;
  const size_t taille =
      sizeof(struct anneau_entete) + (size_t)capacite * 8u;
  struct anneau_entete *e =
      mmap(NULL, taille, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS,
           -1, 0);
  if (e == MAP_FAILED) {
    printf("ÉCHEC : mmap partagé\n");
    return 1;
  }

  verifier(anneau_initialiser(e, 2, 8, 48000, 64, capacite, 42) == 0,
           "fork : initialisation");
  uint32_t source[16 * 2];
  remplir(source, 0, 10);
  verifier(anneau_ecrire(e, source, 10) == 10, "fork : écriture du père");
  verifier(atomic_load(&e->ecrit) == 10 && atomic_load(&e->lu) == 0,
           "fork : compteurs du père avant fork");

  const pid_t pid = fork();
  if (pid < 0) {
    printf("ÉCHEC : fork\n");
    munmap(e, taille);
    return 1;
  }

  if (pid == 0) {
    // Fils : les compteurs et les données sont bien partagés. Une écriture
    // légitime avance ecrit sans jamais toucher lu ni corrompre l'anneau.
    if (anneau_disponible(e) != 10 || anneau_place_libre(e) != capacite - 10)
      _exit(1);
    uint32_t fils[5 * 2];
    remplir(fils, 100, 5);
    if (anneau_ecrire(e, fils, 5) != 5) _exit(2);
    if (atomic_load(&e->ecrit) != 15 || atomic_load(&e->lu) != 0) _exit(3);
    if (anneau_disponible(e) != 15 || anneau_place_libre(e) != capacite - 15)
      _exit(4);
    _exit(0);
  }

  int statut = 0;
  verifier(waitpid(pid, &statut, 0) == pid, "fork : attente du fils");
  verifier(WIFEXITED(statut) && WEXITSTATUS(statut) == 0,
           "fork : le fils voit les compteurs partagés");

  verifier(atomic_load(&e->ecrit) == 15, "fork : ecrit vu par le père");
  verifier(atomic_load(&e->lu) == 0, "fork : lu du père intact");
  verifier(anneau_disponible(e) == 15, "fork : 15 trames disponibles");
  verifier(anneau_place_libre(e) == capacite - 15,
           "fork : place libre cohérente");

  uint32_t destination[16 * 2];
  verifier(anneau_lire(e, destination, 15) == 15, "fork : lecture du père");
  verifier(destination_valide(destination, 0, 10),
           "fork : données du père intactes");
  verifier(destination_valide(destination + 10 * 2, 100, 5),
           "fork : données du fils dans l'ordre");
  verifier(atomic_load(&e->ecrit) == 15 && atomic_load(&e->lu) == 15,
           "fork : compteurs cohérents après lecture");
  verifier(anneau_disponible(e) == 0, "fork : anneau vidé");
  verifier(atomic_load(&e->overruns) == 0 &&
               atomic_load(&e->underruns) == 0,
           "fork : aucun incident parasite");

  munmap(e, taille);
  if (echecs == 0) {
    printf("-- anneau audio après fork : OK\n");
    return 0;
  }
  printf("-- anneau audio après fork : %d échec(s)\n", echecs);
  return 1;
}
