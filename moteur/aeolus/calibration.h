#pragma once

// Micro-banc autonome de calibration de la qualité (étape Q3a).
//
// Ce module n'instancie PAS aeolus::Engine : il mesure uniquement les classes
// dsp du moteur (SpatialSource, BiquadFilter, Convolver) sur des données
// factices, puis applique un modèle de coût pour choisir un niveau 0..3.
//
// L'API publique est la fonction C `aeolus_calibrer` déclarée dans
// api/aeolus_c.h (avec la structure `aeolus_calibrage`).

#include "aeolus_c.h"

namespace aeolus {
namespace calibration {

// Bornes de temps du micro-banc (voir calibration.cpp).
constexpr double OBJECTIF_MS = 400.0;
constexpr double GARANTIE_MS = 1500.0;

} // namespace calibration
} // namespace aeolus
