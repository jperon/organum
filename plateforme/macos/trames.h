// Tronc commun des codecs de trames de la socket macOS : enveloppe de trame,
// décodeur alimentable octet par octet, encodeur, poignée de main de huit
// octets et résolution du chemin de socket. Les parties propres à un
// protocole (types, validation des corps) vivent dans trames_midi.h et
// trames_audio.h, qui incluent ce fichier.
//
// Aucune allocation, aucun appel système, aucune dépendance hors
// <stddef.h>, <stdint.h> et <string.h> : tout est static inline.
#pragma once

#include <stddef.h>
#include <stdint.h>
#include <string.h>

// Trame : type u8, flags u8, longueur LE16, puis corps.
#define TRAMES_ENTETE_TAILLE 4

// Poignée de main : magic ASCII de quatre octets, version, statut, max_frame
// LE16 (soit huit octets au total).
#define TRAMES_POIGNEE_TAILLE 8

#define TRAMES_MAX_FRAME_MIN 64
#define TRAMES_MAX_FRAME_MAX 8192

// Types communs à tous les protocoles de la socket. Les plages propres à un
// protocole sont définies par son en-tête ; un type inconnu est toujours
// ignoré par l'appelant (extensibilité).
#define TRAMES_TYPE_PING 0x30
#define TRAMES_TYPE_PONG 0x31
#define TRAMES_TYPE_BYE 0x7E

// sizeof(sun_path) sur XNU ; le chemin doit tenir sans le NUL final, soit au
// plus 103 octets. Aucune troncature silencieuse : au-delà, refus explicite.
#define TRAMES_SUN_PATH_MAX 104

struct trame_vue {
  uint8_t type;
  uint8_t flags;
  uint16_t longueur;
  // Pointe dans le tampon du décodeur : valable jusqu'au prochain décodage.
  const uint8_t *corps;
};

struct trame_decodeur {
  uint16_t max_frame;
  uint16_t recus;  // octets d'en-tête accumulés (0..4)
  uint8_t entete[TRAMES_ENTETE_TAILLE];
  uint8_t type;
  uint8_t flags;
  uint16_t corps_attendu;
  uint16_t corps_recus;
  uint8_t corps[TRAMES_MAX_FRAME_MAX];
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
    if (d->recus == TRAMES_ENTETE_TAILLE) {
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
    if (d->recus == TRAMES_ENTETE_TAILLE) {
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
  if (capacite < TRAMES_ENTETE_TAILLE + (size_t)longueur) return -1;
  if (corps == NULL && longueur != 0) return -1;
  sortie[0] = type;
  sortie[1] = flags;
  sortie[2] = (uint8_t)(longueur & 0xFF);
  sortie[3] = (uint8_t)(longueur >> 8);
  if (longueur != 0) memcpy(sortie + TRAMES_ENTETE_TAILLE, corps, longueur);
  return (int)(TRAMES_ENTETE_TAILLE + (size_t)longueur);
}

// Écrit toujours les 8 octets de la poignée de main, avec le magic et la
// version du protocole appelant.
static inline void poignee_encoder_magie(uint8_t sortie[TRAMES_POIGNEE_TAILLE],
                                         const uint8_t magie[4], uint8_t version,
                                         uint8_t statut, uint16_t max_frame) {
  sortie[0] = magie[0];
  sortie[1] = magie[1];
  sortie[2] = magie[2];
  sortie[3] = magie[3];
  sortie[4] = version;
  sortie[5] = statut;
  sortie[6] = (uint8_t)(max_frame & 0xFF);
  sortie[7] = (uint8_t)(max_frame >> 8);
}

// Décode une poignée de main. Renvoie 1 pour une poignée compatible de
// statut 0, 0 pour une poignée valide de statut non nul (refus à lire dans
// vue->statut), -1 pour un magic invalide, -2 pour une version inconnue,
// -3 pour un max_frame hors 64..8192. Remplit vue autant que possible.
static inline int poignee_decoder_magie(
    const uint8_t entree[TRAMES_POIGNEE_TAILLE], const uint8_t magie[4],
    uint8_t version, struct poignee_vue *vue) {
  vue->version = entree[4];
  vue->statut = entree[5];
  vue->max_frame = (uint16_t)((uint16_t)entree[6] |
                              ((uint16_t)entree[7] << 8));
  if (entree[0] != magie[0] || entree[1] != magie[1] || entree[2] != magie[2] ||
      entree[3] != magie[3])
    return -1;
  if (vue->version != version) return -2;
  if (vue->max_frame < TRAMES_MAX_FRAME_MIN ||
      vue->max_frame > TRAMES_MAX_FRAME_MAX)
    return -3;
  return vue->statut == 0 ? 1 : 0;
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

// Résout le chemin d'une socket de la forme <tmpdir>/<nom><uid>.sock :
// socket_env (non vide) prioritaire, sinon tmpdir (ou /tmp), sinon refus si
// le chemin ne tient pas dans la socket (jamais de troncature). nom ne
// commence pas par une barre (« organum-midi- », « organum-audio- »).
// tmpdir et socket_env sont passés en paramètre pour rester testables sans
// getenv.
static inline int trame_chemin_socket_nom(const char *socket_env,
                                          const char *tmpdir,
                                          unsigned long uid, const char *nom,
                                          char *sortie, size_t capacite) {
  if (socket_env != NULL && socket_env[0] != '\0') {
    const size_t taille = strlen(socket_env);
    if (taille >= TRAMES_SUN_PATH_MAX || taille >= capacite) return -1;
    memcpy(sortie, socket_env, taille + 1);
    return 0;
  }

  const char *base = (tmpdir != NULL && tmpdir[0] != '\0') ? tmpdir : "/tmp";
  const size_t base_len = strlen(base);
  const int barre = (base_len > 0 && base[base_len - 1] == '/') ? 0 : 1;

  const size_t nom_len = strlen(nom);

  static const char fin[] = ".sock";

  char uid_txt[24];
  const size_t uid_len = trame_uint_decimal(uid_txt, sizeof uid_txt, uid);
  if (uid_len == 0) return -1;

  const size_t total = base_len + (size_t)barre + nom_len + uid_len +
                       (sizeof fin - 1);
  if (total >= TRAMES_SUN_PATH_MAX || total >= capacite) return -1;

  size_t i = 0;
  memcpy(sortie + i, base, base_len);
  i += base_len;
  if (barre) sortie[i++] = '/';
  memcpy(sortie + i, nom, nom_len);
  i += nom_len;
  memcpy(sortie + i, uid_txt, uid_len);
  i += uid_len;
  memcpy(sortie + i, fin, sizeof fin - 1);
  i += sizeof fin - 1;
  sortie[i] = '\0';
  return 0;
}

// Résout le chemin de la socket MIDI : ORGANUM_MIDI_SOCKET (non vide)
// prioritaire, sinon <tmpdir>/organum-midi-<uid>.sock, sinon
// /tmp/organum-midi-<uid>.sock. Renvoie 0 en cas de succès, -1 si le chemin
// ne tient pas dans la socket (jamais de troncature).
static inline int trame_chemin_socket(const char *socket_env, const char *tmpdir,
                                      unsigned long uid, char *sortie,
                                      size_t capacite) {
  return trame_chemin_socket_nom(socket_env, tmpdir, uid, "organum-midi-",
                                 sortie, capacite);
}
