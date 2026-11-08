// Codec du protocole de la socket MIDI macOS, isolé du module Lua et de
// CoreMIDI pour être éprouvé sans cosmocc ni assistant externe
// (plateforme/tests/trames_midi.c). La spécification de référence est
// plateforme/macos/PROTOCOLE-MIDI.md.
//
// Aucune allocation, aucun appel système, aucune dépendance hors
// <stddef.h>, <stdint.h> et <string.h> : tout est static inline. Le décodeur
// accepte une alimentation octet par octet.
#pragma once

#include <stddef.h>
#include <stdint.h>
#include <string.h>

// Poignée de main : « OMID », version 1, un octet de statut, max_frame LE16.
#define TRAMES_MIDI_MAGIC_0 'O'
#define TRAMES_MIDI_MAGIC_1 'M'
#define TRAMES_MIDI_MAGIC_2 'I'
#define TRAMES_MIDI_MAGIC_3 'D'
#define TRAMES_MIDI_VERSION 1
#define TRAMES_MIDI_POIGNEE_TAILLE 8

#define TRAMES_MIDI_STATUT_OK 0
#define TRAMES_MIDI_STATUT_VERSION 1
#define TRAMES_MIDI_STATUT_CLIENT 2
#define TRAMES_MIDI_STATUT_INTERNE 3

#define TRAMES_MIDI_MAX_FRAME_MIN 64
#define TRAMES_MIDI_MAX_FRAME_MAX 8192

// Trame : type u8, flags u8, longueur LE16, puis corps.
#define TRAMES_MIDI_ENTETE_TAILLE 4

#define TRAMES_MIDI_TYPE_MIDI 0x01
#define TRAMES_MIDI_TYPE_SYSEX 0x02
#define TRAMES_MIDI_TYPE_DEVICE_LIST 0x10
#define TRAMES_MIDI_TYPE_DEVICE_EVENT 0x11
#define TRAMES_MIDI_TYPE_SUBSCRIBE 0x20
#define TRAMES_MIDI_TYPE_PING 0x30
#define TRAMES_MIDI_TYPE_PONG 0x31
#define TRAMES_MIDI_TYPE_BYE 0x7E

// Bit 0 des drapeaux d'une trame SYSEX : d'autres morceaux suivent.
#define TRAMES_MIDI_FLAG_SUITE 0x01

// Capacités d'un périphérique (DEVICE_LIST).
#define TRAMES_MIDI_CAPACITE_SOURCE 0x01
#define TRAMES_MIDI_CAPACITE_DESTINATION 0x02

#define TRAMES_MIDI_PERIPHERIQUES_MAX 32
#define TRAMES_MIDI_NOM_MAX 63

// sizeof(sun_path) sur XNU ; le chemin doit tenir sans le NUL final, soit au
// plus 103 octets. Aucune troncature silencieuse : au-delà, refus explicite.
#define TRAMES_MIDI_SUN_PATH_MAX 104

struct trame_vue {
  uint8_t type;
  uint8_t flags;
  uint16_t longueur;
  // Pointe dans le tampon du décodeur : valable jusqu'au prochain décodage.
  const uint8_t *corps;
};

struct peripherique_vue {
  uint8_t id;
  uint8_t capacites;
  uint8_t nom_len;
  // Pointe dans le corps de la trame, sans NUL final.
  const uint8_t *nom;
};

struct trame_decodeur {
  uint16_t max_frame;
  uint16_t recus;  // octets d'en-tête accumulés (0..4)
  uint8_t entete[TRAMES_MIDI_ENTETE_TAILLE];
  uint8_t type;
  uint8_t flags;
  uint16_t corps_attendu;
  uint16_t corps_recus;
  uint8_t corps[TRAMES_MIDI_MAX_FRAME_MAX];
};

struct poignee_vue {
  uint8_t version;
  uint8_t statut;
  uint16_t max_frame;
};

static inline void trame_decodeur_init(struct trame_decodeur *d,
                                       uint16_t max_frame) {
  d->max_frame = max_frame;
  d->recus = 0;
  d->type = 0;
  d->flags = 0;
  d->corps_attendu = 0;
  d->corps_recus = 0;
}

// Décode au plus une trame dans octets[0..n). Renvoie 1 quand une trame est
// prête (consommes reçoit le nombre d'octets utilisés), 0 s'il faut encore
// des octets, -1 si la longueur annoncée dépasse max_frame (erreur de
// décodage : l'appelant ferme la connexion).
static inline int trame_decoder(struct trame_decodeur *d,
                                const uint8_t *octets, size_t n,
                                struct trame_vue *vue, size_t *consommes) {
  size_t i = 0;
  for (;;) {
    if (d->recus == TRAMES_MIDI_ENTETE_TAILLE) {
      if (d->corps_recus == d->corps_attendu) {
        vue->type = d->type;
        vue->flags = d->flags;
        vue->longueur = d->corps_attendu;
        vue->corps = d->corps;
        d->recus = 0;
        d->corps_recus = 0;
        d->corps_attendu = 0;
        *consommes = i;
        return 1;
      }
      if (i == n) {
        *consommes = i;
        return 0;
      }
      {
        uint16_t reste = (uint16_t)(d->corps_attendu - d->corps_recus);
        size_t dispo = n - i;
        size_t prendre = reste < dispo ? (size_t)reste : dispo;
        memcpy(d->corps + d->corps_recus, octets + i, prendre);
        d->corps_recus = (uint16_t)(d->corps_recus + prendre);
        i += prendre;
      }
      continue;
    }

    if (i == n) {
      *consommes = i;
      return 0;
    }
    d->entete[d->recus++] = octets[i++];
    if (d->recus == TRAMES_MIDI_ENTETE_TAILLE) {
      d->type = d->entete[0];
      d->flags = d->entete[1];
      d->corps_attendu = (uint16_t)((uint16_t)d->entete[2] |
                                    ((uint16_t)d->entete[3] << 8));
      if (d->corps_attendu > d->max_frame) {
        *consommes = i;
        return -1;
      }
      d->corps_recus = 0;
    }
  }
}

// Encode une trame complète. Renvoie sa longueur, ou -1 si la capacité est
// insuffisante.
static inline int trame_encoder(uint8_t *sortie, size_t capacite, uint8_t type,
                                uint8_t flags, const uint8_t *corps,
                                uint16_t longueur) {
  if (capacite < TRAMES_MIDI_ENTETE_TAILLE + (size_t)longueur) return -1;
  if (corps == NULL && longueur != 0) return -1;
  sortie[0] = type;
  sortie[1] = flags;
  sortie[2] = (uint8_t)(longueur & 0xFF);
  sortie[3] = (uint8_t)(longueur >> 8);
  if (longueur != 0) memcpy(sortie + TRAMES_MIDI_ENTETE_TAILLE, corps, longueur);
  return (int)(TRAMES_MIDI_ENTETE_TAILLE + (size_t)longueur);
}

// Écrit toujours les 8 octets de la poignée de main.
static inline void poignee_encoder(uint8_t sortie[TRAMES_MIDI_POIGNEE_TAILLE],
                                   uint8_t statut, uint16_t max_frame) {
  sortie[0] = (uint8_t)TRAMES_MIDI_MAGIC_0;
  sortie[1] = (uint8_t)TRAMES_MIDI_MAGIC_1;
  sortie[2] = (uint8_t)TRAMES_MIDI_MAGIC_2;
  sortie[3] = (uint8_t)TRAMES_MIDI_MAGIC_3;
  sortie[4] = (uint8_t)TRAMES_MIDI_VERSION;
  sortie[5] = statut;
  sortie[6] = (uint8_t)(max_frame & 0xFF);
  sortie[7] = (uint8_t)(max_frame >> 8);
}

// Décode une poignée de main. Renvoie 1 pour une poignée compatible de
// statut 0, 0 pour une poignée valide de statut non nul (refus à lire dans
// vue->statut), -1 pour un magic invalide, -2 pour une version inconnue,
// -3 pour un max_frame hors 64..8192. Remplit vue autant que possible.
static inline int poignee_decoder(const uint8_t entree[TRAMES_MIDI_POIGNEE_TAILLE],
                                  struct poignee_vue *vue) {
  vue->version = entree[4];
  vue->statut = entree[5];
  vue->max_frame = (uint16_t)((uint16_t)entree[6] |
                              ((uint16_t)entree[7] << 8));
  if (entree[0] != (uint8_t)TRAMES_MIDI_MAGIC_0 ||
      entree[1] != (uint8_t)TRAMES_MIDI_MAGIC_1 ||
      entree[2] != (uint8_t)TRAMES_MIDI_MAGIC_2 ||
      entree[3] != (uint8_t)TRAMES_MIDI_MAGIC_3)
    return -1;
  if (vue->version != TRAMES_MIDI_VERSION) return -2;
  if (vue->max_frame < TRAMES_MIDI_MAX_FRAME_MIN ||
      vue->max_frame > TRAMES_MIDI_MAX_FRAME_MAX)
    return -3;
  return vue->statut == TRAMES_MIDI_STATUT_OK ? 1 : 0;
}

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

// Écrit en décimal sans allocation. Renvoie le nombre de chiffres, ou 0 si
// la capacité est insuffisante.
static inline size_t trame_uint_decimal(char *sortie, size_t capacite,
                                        unsigned long valeur) {
  char chiffres[24];
  size_t n = 0;
  do {
    chiffres[n++] = (char)('0' + (int)(valeur % 10));
    valeur /= 10;
  } while (valeur != 0);
  if (n >= capacite) return 0;
  for (size_t i = 0; i < n; ++i) sortie[i] = chiffres[n - 1 - i];
  return n;
}

// Résout le chemin de la socket MIDI : ORGANUM_MIDI_SOCKET (non vide)
// prioritaire, sinon <tmpdir>/organum-midi-<uid>.sock, sinon
// /tmp/organum-midi-<uid>.sock. Renvoie 0 en cas de succès, -1 si le chemin
// ne tient pas dans la socket (jamais de troncature). tmpdir et socket_env
// sont passés en paramètre pour rester testables sans getenv.
static inline int trame_chemin_socket(const char *socket_env, const char *tmpdir,
                                      unsigned long uid, char *sortie,
                                      size_t capacite) {
  if (socket_env != NULL && socket_env[0] != '\0') {
    const size_t taille = strlen(socket_env);
    if (taille >= TRAMES_MIDI_SUN_PATH_MAX || taille >= capacite) return -1;
    memcpy(sortie, socket_env, taille + 1);
    return 0;
  }

  const char *base = (tmpdir != NULL && tmpdir[0] != '\0') ? tmpdir : "/tmp";
  const size_t base_len = strlen(base);
  const int barre = (base_len > 0 && base[base_len - 1] == '/') ? 0 : 1;

  static const char milieu[] = "/organum-midi-";
  static const char fin[] = ".sock";

  char uid_txt[24];
  const size_t uid_len = trame_uint_decimal(uid_txt, sizeof uid_txt, uid);
  if (uid_len == 0) return -1;

  const size_t total = base_len + (size_t)barre + (sizeof milieu - 1) + uid_len +
                       (sizeof fin - 1);
  if (total >= TRAMES_MIDI_SUN_PATH_MAX || total >= capacite) return -1;

  size_t i = 0;
  memcpy(sortie + i, base, base_len);
  i += base_len;
  if (barre) sortie[i++] = '/';
  memcpy(sortie + i, milieu + 1, sizeof milieu - 2);  // sans la barre initiale
  i += sizeof milieu - 2;
  memcpy(sortie + i, uid_txt, uid_len);
  i += uid_len;
  memcpy(sortie + i, fin, sizeof fin - 1);
  i += sizeof fin - 1;
  sortie[i] = '\0';
  return 0;
}
