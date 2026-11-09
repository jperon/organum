// Codec du protocole de la socket MIDI macOS, isolé du module Lua et de
// CoreMIDI pour être éprouvé sans cosmocc ni assistant externe
// (plateforme/tests/trames_midi.c). La spécification de référence est
// plateforme/macos/PROTOCOLE-MIDI.md.
//
// Le tronc commun (enveloppe, décodeur, encodeur, poignée, chemin de socket)
// vit dans trames.h ; ce fichier n'ajoute que le vocabulaire MIDI et la
// validation de ses corps. Aucune allocation, aucun appel système.
#pragma once

#include "trames.h"

// Poignée de main : « OMID », version 1, un octet de statut, max_frame LE16.
#define TRAMES_MIDI_MAGIC_0 'O'
#define TRAMES_MIDI_MAGIC_1 'M'
#define TRAMES_MIDI_MAGIC_2 'I'
#define TRAMES_MIDI_MAGIC_3 'D'
#define TRAMES_MIDI_VERSION 1
#define TRAMES_MIDI_POIGNEE_TAILLE TRAMES_POIGNEE_TAILLE

#define TRAMES_MIDI_STATUT_OK 0
#define TRAMES_MIDI_STATUT_VERSION 1
#define TRAMES_MIDI_STATUT_CLIENT 2
#define TRAMES_MIDI_STATUT_INTERNE 3

#define TRAMES_MIDI_MAX_FRAME_MIN TRAMES_MAX_FRAME_MIN
#define TRAMES_MIDI_MAX_FRAME_MAX TRAMES_MAX_FRAME_MAX

#define TRAMES_MIDI_ENTETE_TAILLE TRAMES_ENTETE_TAILLE

#define TRAMES_MIDI_TYPE_MIDI 0x01
#define TRAMES_MIDI_TYPE_SYSEX 0x02
#define TRAMES_MIDI_TYPE_DEVICE_LIST 0x10
#define TRAMES_MIDI_TYPE_DEVICE_EVENT 0x11
#define TRAMES_MIDI_TYPE_SUBSCRIBE 0x20
#define TRAMES_MIDI_TYPE_PING TRAMES_TYPE_PING
#define TRAMES_MIDI_TYPE_PONG TRAMES_TYPE_PONG
#define TRAMES_MIDI_TYPE_BYE TRAMES_TYPE_BYE

// Bit 0 des drapeaux d'une trame SYSEX : d'autres morceaux suivent.
#define TRAMES_MIDI_FLAG_SUITE 0x01

// Capacités d'un périphérique (DEVICE_LIST).
#define TRAMES_MIDI_CAPACITE_SOURCE 0x01
#define TRAMES_MIDI_CAPACITE_DESTINATION 0x02

#define TRAMES_MIDI_PERIPHERIQUES_MAX 32
#define TRAMES_MIDI_NOM_MAX 63

#define TRAMES_MIDI_SUN_PATH_MAX TRAMES_SUN_PATH_MAX

// Magic et version du protocole MIDI, en un seul endroit pour les fonctions
// de poignée de main du tronc commun.
static inline void poignee_encoder(uint8_t sortie[TRAMES_MIDI_POIGNEE_TAILLE],
                                   uint8_t statut, uint16_t max_frame) {
  static const uint8_t magie[4] = {TRAMES_MIDI_MAGIC_0, TRAMES_MIDI_MAGIC_1,
                                   TRAMES_MIDI_MAGIC_2, TRAMES_MIDI_MAGIC_3};
  poignee_encoder_magie(sortie, magie, TRAMES_MIDI_VERSION, statut, max_frame);
}

// Décode une poignée de main MIDI. Mêmes codes de retour que
// poignee_decoder_magie : 1 acceptée, 0 valide mais refusée, -1 magic, -2
// version, -3 max_frame hors bornes.
static inline int poignee_decoder(const uint8_t entree[TRAMES_MIDI_POIGNEE_TAILLE],
                                  struct poignee_vue *vue) {
  static const uint8_t magie[4] = {TRAMES_MIDI_MAGIC_0, TRAMES_MIDI_MAGIC_1,
                                   TRAMES_MIDI_MAGIC_2, TRAMES_MIDI_MAGIC_3};
  return poignee_decoder_magie(entree, magie, TRAMES_MIDI_VERSION, vue);
}

struct peripherique_vue {
  uint8_t id;
  uint8_t capacites;
  uint8_t nom_len;
  // Pointe dans le corps de la trame, sans NUL final.
  const uint8_t *nom;
};

// Valide un corps de trame MIDI : 1 à 3 octets, statut de canal 0x80..0xEF,
// longueur cohérente avec ce statut.
static inline int trame_midi_valide(const uint8_t *corps, uint16_t longueur) {
  if (longueur < 1 || longueur > 3) return 0;
  const uint8_t statut = corps[0];
  if (statut < 0x80 || statut > 0xEF) return 0;
  const uint8_t famille = (uint8_t)(statut & 0xF0);
  const uint16_t attendue =
      (famille == 0xC0 || famille == 0xD0) ? (uint16_t)2 : (uint16_t)3;
  return longueur == attendue;
}

// Analyse le corps d'une DEVICE_LIST (n u8 puis n entrées). Renvoie le nombre
// d'entrées rangées dans sortie (au plus capacite, au plus 32), ou -1 si le
// corps est vide ou si un nom dépasse 63 octets. Un n menti est tronqué au
// nombre d'entrées complètes réellement présentes.
static inline int peripheriques_parser(const uint8_t *corps, uint16_t longueur,
                                       struct peripherique_vue *sortie,
                                       size_t capacite) {
  if (longueur < 1) return -1;
  if (capacite > TRAMES_MIDI_PERIPHERIQUES_MAX)
    capacite = TRAMES_MIDI_PERIPHERIQUES_MAX;

  const unsigned int n = corps[0];
  size_t i = 1;
  size_t ranges = 0;
  for (unsigned int k = 0; k < n; ++k) {
    if (i + 2 > longueur) break;  // en-tête d'entrée incomplet : troncature
    const uint8_t id = corps[i];
    const uint8_t capacites = corps[i + 1];
    const uint8_t nom_len = corps[i + 2];
    i += 3;
    if (nom_len > TRAMES_MIDI_NOM_MAX) return -1;
    if (i + nom_len > longueur) break;  // nom incomplet : troncature
    if (ranges < capacite) {
      sortie[ranges].id = id;
      sortie[ranges].capacites = capacites;
      sortie[ranges].nom_len = nom_len;
      sortie[ranges].nom = corps + i;
      ++ranges;
    }
    i += nom_len;
  }
  return (int)ranges;
}
