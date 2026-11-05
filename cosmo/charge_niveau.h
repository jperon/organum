// Règle de la puce d'adaptation, isolée du reste du module Lua pour être
// éprouvée sans cosmocc ni moteur (cosmo/tests/charge_niveau.c).
#pragma once

// Calcule le niveau sur des entiers : jamais de vert sans mesure.
static inline int calculer_charge_niveau(int pointe, int recents, int evaluee) {
  if (pointe >= 90 || recents >= 3) return 3;
  if (pointe >= 65 || recents >= 1) return 2;
  if (evaluee && recents == 0) return 1;
  return 0;
}
