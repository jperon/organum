// Décision de cadencement de la boucle audio, isolée du module Lua pour être
// éprouvée sans cosmocc ni moteur (cosmo/tests/sortie_null.c).
//
// Seul le périphérique effectif « null » d'ALSA rend la main aussitôt :
// l'absence de nom, « default » (le défaut) et tout autre nom gardent le
// rythme du pilote et ne doivent rien changer.
#pragma once

#include <string.h>

static inline int sortie_est_null(const char *nom) {
  return nom != NULL && strcmp(nom, "null") == 0;
}
