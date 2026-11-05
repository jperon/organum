// Règle de cadencement de la sortie « null » (cosmo/sortie_null.h) : seul le
// nom exact « null » active l'attente ; le défaut et les noms voisins non.
#include "sortie_null.h"

#include <stdio.h>

static int echecs;

static void verifier(const char *nom, int attendu) {
  int obtenu = sortie_est_null(nom);
  if (obtenu != attendu) {
    printf("ÉCHEC : nom=%s : attendu %d, obtenu %d\n",
           nom ? nom : "(nul)", attendu, obtenu);
    ++echecs;
  }
}

int main(void) {
  verifier("null", 1);
  verifier("default", 0);
  verifier("", 0);
  verifier(NULL, 0);
  verifier("nullx", 0);
  verifier("xnull", 0);
  verifier("plughw:2,1", 0);
  verifier("hw:2,0", 0);
  verifier("NULL", 0);

  if (echecs == 0) {
    printf("-- sortie_null : OK\n");
    return 0;
  }
  printf("-- sortie_null : %d échec(s)\n", echecs);
  return 1;
}
