// Règle du niveau de charge (cosmo/charge_niveau.h) : table de vérité et
// bornes, sans moteur ni Lua.
#include "charge_niveau.h"

#include <stdio.h>

static int echecs;

static void verifier(int condition, const char *message) {
  if (!condition) {
    printf("ÉCHEC : %s\n", message);
    ++echecs;
  }
}

static void cas(int pointe, int recents, int evaluee, int attendu) {
  int obtenu = calculer_charge_niveau(pointe, recents, evaluee);
  if (obtenu != attendu) {
    printf("ÉCHEC : pointe=%d recents=%d evaluee=%d : attendu %d, obtenu %d\n",
           pointe, recents, evaluee, attendu, obtenu);
    ++echecs;
  }
}

int main(void) {
  // Aucune mesure : toujours gris, sauf xruns.
  verifier(calculer_charge_niveau(0, 0, 0) == 0, "sans mesure : gris");
  verifier(calculer_charge_niveau(50, 0, 0) == 0, "50 % sans mesure : gris");
  verifier(calculer_charge_niveau(89, 0, 0) == 2, "89 % sans mesure : orange");

  // Une seconde de jeu mesurée, sans xrun : vert.
  verifier(calculer_charge_niveau(0, 0, 1) == 1, "mesuré à 0 % : vert");
  verifier(calculer_charge_niveau(64, 0, 1) == 1, "64 % : vert");

  // Orange dès 65 % ou un xrun récent.
  verifier(calculer_charge_niveau(65, 0, 1) == 2, "65 % : orange");
  verifier(calculer_charge_niveau(89, 0, 1) == 2, "89 % : orange");
  verifier(calculer_charge_niveau(0, 1, 1) == 2, "un xrun : orange");
  verifier(calculer_charge_niveau(0, 2, 1) == 2, "deux xruns : orange");

  // Rouge dès 90 % ou trois xruns récents.
  verifier(calculer_charge_niveau(90, 0, 1) == 3, "90 % : rouge");
  verifier(calculer_charge_niveau(100, 0, 0) == 3, "100 % sans mesure : rouge");
  verifier(calculer_charge_niveau(0, 3, 1) == 3, "trois xruns : rouge");
  verifier(calculer_charge_niveau(0, 10, 0) == 3, "dix xruns sans mesure : rouge");

  // Bornes exactes et valeurs négatives.
  cas(64, 0, 1, 1);
  cas(65, 0, 1, 2);
  cas(89, 0, 1, 2);
  cas(90, 0, 1, 3);
  cas(0, 0, 1, 1);
  cas(0, 1, 1, 2);
  cas(0, 2, 1, 2);
  cas(0, 3, 1, 3);
  cas(-1, 0, 1, 1);
  cas(0, -1, 1, 0);
  cas(0, 0, 2, 1);

  if (echecs == 0) {
    printf("-- charge_niveau : OK\n");
    return 0;
  }
  printf("-- charge_niveau : %d échec(s)\n", echecs);
  return 1;
}
