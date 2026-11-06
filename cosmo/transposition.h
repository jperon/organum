// Transpositeur MIDI global, isolé du reste du module Lua pour être éprouvé
// sans cosmocc ni moteur (cosmo/tests/transposition.c).
//
// Seules la note d'appui, la note de relâchement et la pression polyphonique
// sont décalées ; tous les autres messages passent inchangés. Une note tenue
// garde la note réellement envoyée jusqu'à son relâchement, même si la
// transposition change entre-temps : la table [canal][note reçue] retient
// cette note. Aucun verrou, aucune allocation, aucun appel système : la table
// n'est touchée que par le fil audio.
#pragma once

#include <stdint.h>
#include <string.h>

#define TRANSPOSITION_MIN (-12)
#define TRANSPOSITION_MAX 12

struct transposition_etat {
  // -1 : aucune note tenue pour ce couple (canal, note reçue).
  int8_t note[16][128];
};

static inline void transposition_reinitialiser(struct transposition_etat *t) {
  memset(t->note, -1, sizeof(t->note));
}

// Filtre un message MIDI de trois octets. Renvoie 1 s'il faut l'envoyer et
// remplit sortie ; renvoie 0 pour l'ignorer (note hors 0..127 après décalage,
// ou relâchement d'une note qui n'avait pas été retenue).
static inline int transposition_filtrer(struct transposition_etat *t,
                                        int transposition,
                                        const unsigned char entree[3],
                                        unsigned char sortie[3]) {
  sortie[0] = entree[0];
  sortie[1] = entree[1];
  sortie[2] = entree[2];

  const unsigned char statut = entree[0];
  if (statut >= 0xF0) return 1;  // SysEx et messages système : inchangés

  const int canal = statut & 0x0F;
  const int type = statut & 0xF0;

  // Note hors 0..127 : ne jamais indexer la table retenue.
  if ((type == 0x80 || type == 0x90 || type == 0xA0) && entree[1] > 127)
    return 0;

  // Appui : vélocité strictement positive. Une vélocité nulle est un
  // relâchement (traitée plus bas).
  if (type == 0x90 && entree[2] > 0) {
    const int note = (int)entree[1] + transposition;
    if (note < 0 || note > 127) return 0;
    t->note[canal][entree[1]] = (int8_t)note;
    sortie[1] = (unsigned char)note;
    return 1;
  }

  // Relâchement (0x8n, ou 0x9n de vélocité nulle) : renvoyer la note retenue
  // à l'appui, jamais la note reçue décalée avec la valeur courante.
  if (type == 0x80 || type == 0x90) {
    const int retenue = t->note[canal][entree[1]];
    if (retenue < 0) return 0;
    t->note[canal][entree[1]] = -1;
    sortie[1] = (unsigned char)retenue;
    return 1;
  }

  // Pression polyphonique : viser la note réellement tenue si elle existe.
  if (type == 0xA0) {
    const int retenue = t->note[canal][entree[1]];
    if (retenue >= 0) sortie[1] = (unsigned char)retenue;
    return 1;
  }

  return 1;
}
