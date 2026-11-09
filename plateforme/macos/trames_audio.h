// Codec des trames audio du protocole de la socket macOS. Il réutilise le
// tronc commun de trames.h (enveloppe, décodeur, encodeur, poignée, types
// PING/PONG/BYE) et n'ajoute que les messages propres au flux audio.
//
// Aucune allocation, aucun appel système, aucune dépendance hors
// <stddef.h>, <stdint.h> et <string.h>. Les corps sont bornés et les
// décodeurs refusent les longueurs malformées ; un type inconnu reste ignoré
// par l'appelant comme pour le protocole MIDI.
#pragma once

#include "trames.h"

// Poignée de main : « OAUD ». La version couvre le protocole de contrôle ET
// la disposition de l'anneau partagé (anneau_audio.h) : les deux binaires
// doivent être recompilés ensemble. Version 2 : drapeau demarre dans l'en-tête
// de l'anneau. Toute modification de la disposition impose d'incrémenter les
// deux constantes et de REFUSER un couple hétérogène.
#define TRAMES_AUDIO_MAGIC_0 'O'
#define TRAMES_AUDIO_MAGIC_1 'A'
#define TRAMES_AUDIO_MAGIC_2 'U'
#define TRAMES_AUDIO_MAGIC_3 'D'
#define TRAMES_AUDIO_VERSION 2
#define TRAMES_AUDIO_POIGNEE_TAILLE TRAMES_POIGNEE_TAILLE

#define TRAMES_AUDIO_TYPE_CONFIG 0x40
#define TRAMES_AUDIO_TYPE_ACK 0x41
#define TRAMES_AUDIO_TYPE_DEVICE 0x42
#define TRAMES_AUDIO_TYPE_STOP 0x43
#define TRAMES_AUDIO_TYPE_PING TRAMES_TYPE_PING
#define TRAMES_AUDIO_TYPE_PONG TRAMES_TYPE_PONG
#define TRAMES_AUDIO_TYPE_BYE TRAMES_TYPE_BYE

// Statuts d'AUDIO_ACK.
#define TRAMES_AUDIO_STATUT_OK 0
#define TRAMES_AUDIO_STATUT_FORMAT 1
#define TRAMES_AUDIO_STATUT_AUCUNE_SORTIE 2
#define TRAMES_AUDIO_STATUT_CONFIG 3
#define TRAMES_AUDIO_STATUT_INTERNE 4

// Format 0 : float32 entrelacé, tel que produit boucle_audio.
#define TRAMES_AUDIO_FORMAT_FLOAT32_ENTRELACE 0

#define TRAMES_AUDIO_NOM_MAX 63

// Corps : generation u32, taux u32, periode u32, canaux u16, format u16,
// capacite u32, octets u32.
#define TRAMES_AUDIO_CONFIG_TAILLE 24
// Corps : statut u8, generation u32, taux effectif u32, periode u32,
// capacite u32.
#define TRAMES_AUDIO_ACK_TAILLE 17
// Corps : raison u8.
#define TRAMES_AUDIO_STOP_TAILLE 1
// Corps minimal DEVICE : nom_len u8, puis taux_natif u32 et latence_us u32.
#define TRAMES_AUDIO_DEVICE_TAILLE_MIN 9

struct audio_config_vue {
  uint32_t generation;
  uint32_t taux;
  uint32_t periode;
  uint16_t canaux;
  uint16_t format;
  uint32_t capacite;
  uint32_t octets;
};

struct audio_ack_vue {
  uint8_t statut;
  uint32_t generation;
  uint32_t taux;
  uint32_t periode;
  uint32_t capacite;
};

struct audio_device_vue {
  uint8_t nom_len;
  // Pointe dans le corps de la trame, sans NUL final.
  const uint8_t *nom;
  uint32_t taux_natif;
  uint32_t latence_us;
};

struct audio_stop_vue {
  uint8_t raison;
};

static inline void audio_ecrire_u16(uint8_t *p, uint16_t v) {
  p[0] = (uint8_t)(v & 0xFFu);
  p[1] = (uint8_t)(v >> 8);
}

static inline uint16_t audio_lire_u16(const uint8_t *p) {
  return (uint16_t)((uint16_t)p[0] | ((uint16_t)p[1] << 8));
}

static inline void audio_ecrire_u32(uint8_t *p, uint32_t v) {
  p[0] = (uint8_t)(v & 0xFFu);
  p[1] = (uint8_t)((v >> 8) & 0xFFu);
  p[2] = (uint8_t)((v >> 16) & 0xFFu);
  p[3] = (uint8_t)(v >> 24);
}

static inline uint32_t audio_lire_u32(const uint8_t *p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) |
         ((uint32_t)p[3] << 24);
}

static inline void poignee_audio_encoder(
    uint8_t sortie[TRAMES_AUDIO_POIGNEE_TAILLE], uint8_t statut,
    uint16_t max_frame) {
  static const uint8_t magie[4] = {TRAMES_AUDIO_MAGIC_0, TRAMES_AUDIO_MAGIC_1,
                                   TRAMES_AUDIO_MAGIC_2, TRAMES_AUDIO_MAGIC_3};
  poignee_encoder_magie(sortie, magie, TRAMES_AUDIO_VERSION, statut, max_frame);
}

// Mêmes codes que poignee_decoder_magie : 1 acceptée, 0 valide mais refusée,
// -1 magic, -2 version, -3 max_frame hors bornes.
static inline int poignee_audio_decoder(
    const uint8_t entree[TRAMES_AUDIO_POIGNEE_TAILLE],
    struct poignee_vue *vue) {
  static const uint8_t magie[4] = {TRAMES_AUDIO_MAGIC_0, TRAMES_AUDIO_MAGIC_1,
                                   TRAMES_AUDIO_MAGIC_2, TRAMES_AUDIO_MAGIC_3};
  return poignee_decoder_magie(entree, magie, TRAMES_AUDIO_VERSION, vue);
}

// AUDIO_CONFIG. L'encodeur renvoie la longueur du corps (24) ou -1 si la
// capacité est insuffisante. Le décodeur renvoie 0 en cas de succès, -1 si la
// longueur n'est pas exactement celle du corps attendu.
static inline int audio_config_encoder(uint8_t *sortie, size_t capacite,
                                       const struct audio_config_vue *vue) {
  if (capacite < TRAMES_AUDIO_CONFIG_TAILLE) return -1;
  audio_ecrire_u32(sortie + 0, vue->generation);
  audio_ecrire_u32(sortie + 4, vue->taux);
  audio_ecrire_u32(sortie + 8, vue->periode);
  audio_ecrire_u16(sortie + 12, vue->canaux);
  audio_ecrire_u16(sortie + 14, vue->format);
  audio_ecrire_u32(sortie + 16, vue->capacite);
  audio_ecrire_u32(sortie + 20, vue->octets);
  return TRAMES_AUDIO_CONFIG_TAILLE;
}

static inline int audio_config_decoder(const uint8_t *corps, uint16_t longueur,
                                       struct audio_config_vue *vue) {
  if (corps == NULL || longueur != TRAMES_AUDIO_CONFIG_TAILLE) return -1;
  vue->generation = audio_lire_u32(corps + 0);
  vue->taux = audio_lire_u32(corps + 4);
  vue->periode = audio_lire_u32(corps + 8);
  vue->canaux = audio_lire_u16(corps + 12);
  vue->format = audio_lire_u16(corps + 14);
  vue->capacite = audio_lire_u32(corps + 16);
  vue->octets = audio_lire_u32(corps + 20);
  return 0;
}

// AUDIO_ACK : corps de 17 octets exactement.
static inline int audio_ack_encoder(uint8_t *sortie, size_t capacite,
                                    const struct audio_ack_vue *vue) {
  if (capacite < TRAMES_AUDIO_ACK_TAILLE) return -1;
  sortie[0] = vue->statut;
  audio_ecrire_u32(sortie + 1, vue->generation);
  audio_ecrire_u32(sortie + 5, vue->taux);
  audio_ecrire_u32(sortie + 9, vue->periode);
  audio_ecrire_u32(sortie + 13, vue->capacite);
  return TRAMES_AUDIO_ACK_TAILLE;
}

static inline int audio_ack_decoder(const uint8_t *corps, uint16_t longueur,
                                    struct audio_ack_vue *vue) {
  if (corps == NULL || longueur != TRAMES_AUDIO_ACK_TAILLE) return -1;
  vue->statut = corps[0];
  vue->generation = audio_lire_u32(corps + 1);
  vue->taux = audio_lire_u32(corps + 5);
  vue->periode = audio_lire_u32(corps + 9);
  vue->capacite = audio_lire_u32(corps + 13);
  return 0;
}

// AUDIO_DEVICE : nom_len u8 (au plus 63), nom UTF-8 sans NUL, taux natif u32,
// latence u32. L'encodeur renvoie la longueur du corps ou -1. Le décodeur
// exige une longueur exactement cohérente avec nom_len.
static inline int audio_device_encoder(uint8_t *sortie, size_t capacite,
                                       const struct audio_device_vue *vue) {
  if (vue->nom_len > TRAMES_AUDIO_NOM_MAX) return -1;
  if (vue->nom_len != 0 && vue->nom == NULL) return -1;
  const size_t total = (size_t)TRAMES_AUDIO_DEVICE_TAILLE_MIN + vue->nom_len;
  if (capacite < total) return -1;
  sortie[0] = vue->nom_len;
  if (vue->nom_len != 0) memcpy(sortie + 1, vue->nom, vue->nom_len);
  audio_ecrire_u32(sortie + 1 + vue->nom_len, vue->taux_natif);
  audio_ecrire_u32(sortie + 5 + vue->nom_len, vue->latence_us);
  return (int)total;
}

static inline int audio_device_decoder(const uint8_t *corps, uint16_t longueur,
                                       struct audio_device_vue *vue) {
  if (corps == NULL || longueur < TRAMES_AUDIO_DEVICE_TAILLE_MIN) return -1;
  const uint8_t nom_len = corps[0];
  if (nom_len > TRAMES_AUDIO_NOM_MAX) return -1;
  if (longueur != (uint16_t)(TRAMES_AUDIO_DEVICE_TAILLE_MIN + nom_len))
    return -1;
  vue->nom_len = nom_len;
  vue->nom = corps + 1;
  vue->taux_natif = audio_lire_u32(corps + 1 + nom_len);
  vue->latence_us = audio_lire_u32(corps + 5 + nom_len);
  return 0;
}

// AUDIO_STOP : une raison u8.
static inline int audio_stop_encoder(uint8_t *sortie, size_t capacite,
                                     const struct audio_stop_vue *vue) {
  if (capacite < TRAMES_AUDIO_STOP_TAILLE) return -1;
  sortie[0] = vue->raison;
  return TRAMES_AUDIO_STOP_TAILLE;
}

static inline int audio_stop_decoder(const uint8_t *corps, uint16_t longueur,
                                     struct audio_stop_vue *vue) {
  if (corps == NULL || longueur != TRAMES_AUDIO_STOP_TAILLE) return -1;
  vue->raison = corps[0];
  return 0;
}
