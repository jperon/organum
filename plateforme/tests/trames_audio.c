// Codec des trames audio macOS (plateforme/macos/trames_audio.h) : poignée
// OAUD, CONFIG, ACK, DEVICE, STOP, bornes des corps, types inconnus et
// intégration avec l'enveloppe commune de trames.h.
#include "../macos/trames_audio.h"

#include <stdio.h>

_Static_assert(TRAMES_AUDIO_CONFIG_TAILLE == 24, "corps CONFIG de 24 octets");
_Static_assert(TRAMES_AUDIO_ACK_TAILLE == 17, "corps ACK de 17 octets");
_Static_assert(TRAMES_AUDIO_STOP_TAILLE == 1, "corps STOP de 1 octet");
_Static_assert(TRAMES_AUDIO_DEVICE_TAILLE_MIN == 9,
               "corps DEVICE minimal de 9 octets");
_Static_assert(TRAMES_AUDIO_NOM_MAX == 63, "nom DEVICE au plus 63 octets");
_Static_assert(TRAMES_AUDIO_TYPE_PING == 0x30 &&
                   TRAMES_AUDIO_TYPE_PONG == 0x31 &&
                   TRAMES_AUDIO_TYPE_BYE == 0x7E,
               "PING/PONG/BYE réutilisés");

static int echecs;

static void verifier(int condition, const char *message) {
  if (!condition) {
    printf("ÉCHEC : %s\n", message);
    ++echecs;
  }
}

static int octets_egaux(const uint8_t *a, const uint8_t *b, size_t n) {
  return memcmp(a, b, n) == 0;
}

static void verifier_poignee(const uint8_t *p, int attendu_code,
                             uint8_t attendu_statut,
                             uint16_t attendu_max_frame,
                             const char *message) {
  struct poignee_vue vue;
  const int code = poignee_audio_decoder(p, &vue);
  verifier(code == attendu_code, message);
  verifier(vue.statut == attendu_statut, message);
  verifier(vue.max_frame == attendu_max_frame, message);
}

static void tester_poignee(void) {
  uint8_t poignee[TRAMES_AUDIO_POIGNEE_TAILLE];

  poignee_audio_encoder(poignee, TRAMES_AUDIO_STATUT_OK, 1024);
  verifier(octets_egaux(poignee, (const uint8_t *)"OAUD", 4),
           "poignée : magic OAUD");
  verifier(poignee[4] == TRAMES_AUDIO_VERSION && poignee[5] == 0,
           "poignée : version et statut");
  verifier(poignee[6] == 0x00 && poignee[7] == 0x04,
           "poignée : max_frame en petit-boutiste");
  verifier_poignee(poignee, 1, TRAMES_AUDIO_STATUT_OK, 1024,
                   "poignée : aller-retour accepté");

  poignee_audio_encoder(poignee, TRAMES_AUDIO_STATUT_FORMAT, 512);
  verifier_poignee(poignee, 0, TRAMES_AUDIO_STATUT_FORMAT, 512,
                   "poignée : statut de refus lu");

  poignee_audio_encoder(poignee, TRAMES_AUDIO_STATUT_OK, 256);
  poignee[1] = 'X';
  verifier_poignee(poignee, -1, TRAMES_AUDIO_STATUT_OK, 256,
                   "poignée : mauvais magic refusé");

  poignee_audio_encoder(poignee, TRAMES_AUDIO_STATUT_OK, 256);
  poignee[4] = 2;
  verifier_poignee(poignee, -2, TRAMES_AUDIO_STATUT_OK, 256,
                   "poignée : version 2 refusée");
  poignee[4] = 0;
  verifier_poignee(poignee, -2, TRAMES_AUDIO_STATUT_OK, 256,
                   "poignée : version 0 refusée");

  poignee_audio_encoder(poignee, TRAMES_AUDIO_STATUT_OK,
                        TRAMES_MAX_FRAME_MIN - 1);
  verifier_poignee(poignee, -3, TRAMES_AUDIO_STATUT_OK,
                   TRAMES_MAX_FRAME_MIN - 1,
                   "poignée : max_frame 63 refusé");
  poignee_audio_encoder(poignee, TRAMES_AUDIO_STATUT_OK,
                        TRAMES_MAX_FRAME_MAX + 1);
  verifier_poignee(poignee, -3, TRAMES_AUDIO_STATUT_OK,
                   TRAMES_MAX_FRAME_MAX + 1,
                   "poignée : max_frame 8193 refusé");
  poignee_audio_encoder(poignee, TRAMES_AUDIO_STATUT_OK, TRAMES_MAX_FRAME_MAX);
  verifier_poignee(poignee, 1, TRAMES_AUDIO_STATUT_OK, TRAMES_MAX_FRAME_MAX,
                   "poignée : max_frame 8192 accepté");
}

static void tester_config(void) {
  uint8_t corps[TRAMES_AUDIO_CONFIG_TAILLE + 8];
  struct audio_config_vue ecrit = {7, 48000, 512, 2,
                                   TRAMES_AUDIO_FORMAT_FLOAT32_ENTRELACE,
                                   2048, 8};
  struct audio_config_vue lu;

  verifier(audio_config_encoder(corps, sizeof corps, &ecrit) ==
               TRAMES_AUDIO_CONFIG_TAILLE,
           "CONFIG : longueur du corps");
  verifier(audio_lire_u32(corps + 0) == 7 &&
               audio_lire_u32(corps + 4) == 48000 &&
               audio_lire_u32(corps + 8) == 512 &&
               audio_lire_u16(corps + 12) == 2 &&
               audio_lire_u16(corps + 14) == 0 &&
               audio_lire_u32(corps + 16) == 2048 &&
               audio_lire_u32(corps + 20) == 8,
           "CONFIG : champs en petit-boutiste");
  verifier(audio_config_decoder(corps, TRAMES_AUDIO_CONFIG_TAILLE, &lu) == 0,
           "CONFIG : décodage");
  verifier(lu.generation == 7 && lu.taux == 48000 && lu.periode == 512 &&
               lu.canaux == 2 &&
               lu.format == TRAMES_AUDIO_FORMAT_FLOAT32_ENTRELACE &&
               lu.capacite == 2048 && lu.octets == 8,
           "CONFIG : aller-retour");
  verifier(audio_config_encoder(corps, TRAMES_AUDIO_CONFIG_TAILLE - 1, &ecrit) ==
               -1,
           "CONFIG : capacité d'encodage insuffisante");
  verifier(audio_config_decoder(corps, TRAMES_AUDIO_CONFIG_TAILLE - 1, &lu) ==
               -1,
           "CONFIG : corps tronqué refusé");
  verifier(audio_config_decoder(corps, TRAMES_AUDIO_CONFIG_TAILLE + 1, &lu) ==
               -1,
           "CONFIG : corps trop long refusé");
  verifier(audio_config_decoder(NULL, TRAMES_AUDIO_CONFIG_TAILLE, &lu) == -1,
           "CONFIG : corps absent refusé");
}

static void tester_ack(void) {
  uint8_t corps[TRAMES_AUDIO_ACK_TAILLE + 4];
  for (int statut = 0; statut <= TRAMES_AUDIO_STATUT_INTERNE; ++statut) {
    struct audio_ack_vue ecrit = {(uint8_t)statut, 9, 44100, 256, 1024};
    struct audio_ack_vue lu;
    verifier(audio_ack_encoder(corps, sizeof corps, &ecrit) ==
                 TRAMES_AUDIO_ACK_TAILLE,
             "ACK : longueur du corps");
    verifier(corps[0] == (uint8_t)statut &&
                 audio_lire_u32(corps + 1) == 9 &&
                 audio_lire_u32(corps + 5) == 44100 &&
                 audio_lire_u32(corps + 9) == 256 &&
                 audio_lire_u32(corps + 13) == 1024,
             "ACK : champs et statut");
    verifier(audio_ack_decoder(corps, TRAMES_AUDIO_ACK_TAILLE, &lu) == 0,
             "ACK : décodage");
    verifier(lu.statut == (uint8_t)statut && lu.generation == 9 &&
                 lu.taux == 44100 && lu.periode == 256 &&
                 lu.capacite == 1024,
             "ACK : aller-retour");
  }
  verifier(TRAMES_AUDIO_STATUT_AUCUNE_SORTIE == 2 &&
               TRAMES_AUDIO_STATUT_CONFIG == 3 &&
               TRAMES_AUDIO_STATUT_INTERNE == 4,
           "ACK : valeurs de statut");
  verifier(audio_ack_encoder(corps, TRAMES_AUDIO_ACK_TAILLE - 1, NULL) == -1,
           "ACK : capacité insuffisante");
  {
    struct audio_ack_vue lu;
    verifier(audio_ack_decoder(corps, TRAMES_AUDIO_ACK_TAILLE - 1, &lu) == -1,
             "ACK : 16 octets refusés");
    verifier(audio_ack_decoder(corps, TRAMES_AUDIO_ACK_TAILLE + 1, &lu) == -1,
             "ACK : 18 octets refusés");
  }
}

static void tester_device(void) {
  uint8_t corps[1 + TRAMES_AUDIO_NOM_MAX + 8];
  const uint8_t nom[] = "Clavier";
  struct audio_device_vue ecrit = {(uint8_t)7, nom, 48000, 12000};
  struct audio_device_vue lu;
  const int n = audio_device_encoder(corps, sizeof corps, &ecrit);
  verifier(n == 1 + 7 + 8, "DEVICE : longueur du corps");
  verifier(audio_device_decoder(corps, (uint16_t)n, &lu) == 0,
           "DEVICE : décodage");
  verifier(lu.nom_len == 7 && octets_egaux(lu.nom, nom, 7) &&
               lu.taux_natif == 48000 && lu.latence_us == 12000,
           "DEVICE : aller-retour");
  verifier(audio_device_decoder(corps, (uint16_t)(n - 1), &lu) == -1,
           "DEVICE : corps tronqué refusé");
  verifier(audio_device_decoder(corps, (uint16_t)(n + 1), &lu) == -1,
           "DEVICE : corps trop long refusé");
  verifier(audio_device_encoder(corps, (size_t)n - 1, &ecrit) == -1,
           "DEVICE : capacité insuffisante");

  {
    struct audio_device_vue vide = {0, NULL, 44100, 0};
    const int m = audio_device_encoder(corps, sizeof corps, &vide);
    verifier(m == TRAMES_AUDIO_DEVICE_TAILLE_MIN,
             "DEVICE : nom vide accepté");
    verifier(audio_device_decoder(corps, (uint16_t)m, &lu) == 0 &&
                 lu.nom_len == 0 && lu.taux_natif == 44100,
             "DEVICE : nom vide décodé");
  }

  {
    uint8_t nom_long[TRAMES_AUDIO_NOM_MAX];
    memset(nom_long, 'x', sizeof nom_long);
    struct audio_device_vue trop = {TRAMES_AUDIO_NOM_MAX + 1, nom_long, 1, 1};
    verifier(audio_device_encoder(corps, sizeof corps, &trop) == -1,
             "DEVICE : nom_len 64 refusé à l'encodage");
    struct audio_device_vue sans_nom = {1, NULL, 1, 1};
    verifier(audio_device_encoder(corps, sizeof corps, &sans_nom) == -1,
             "DEVICE : nom absent refusé");

    uint8_t mauvais[TRAMES_AUDIO_DEVICE_TAILLE_MIN + TRAMES_AUDIO_NOM_MAX];
    memset(mauvais, 0, sizeof mauvais);
    mauvais[0] = TRAMES_AUDIO_NOM_MAX + 1;
    verifier(audio_device_decoder(mauvais, (uint16_t)sizeof mauvais, &lu) ==
                 -1,
             "DEVICE : nom_len 64 refusé au décodage");
  }
}

static void tester_stop(void) {
  uint8_t corps[4];
  struct audio_stop_vue ecrit = {3};
  struct audio_stop_vue lu;
  verifier(audio_stop_encoder(corps, sizeof corps, &ecrit) ==
               TRAMES_AUDIO_STOP_TAILLE,
           "STOP : longueur du corps");
  verifier(audio_stop_decoder(corps, TRAMES_AUDIO_STOP_TAILLE, &lu) == 0 &&
               lu.raison == 3,
           "STOP : aller-retour");
  verifier(audio_stop_encoder(corps, 0, &ecrit) == -1,
           "STOP : capacité insuffisante");
  verifier(audio_stop_decoder(corps, 0, &lu) == -1,
           "STOP : corps vide refusé");
  verifier(audio_stop_decoder(corps, 2, &lu) == -1,
           "STOP : corps trop long refusé");
}

static void tester_enveloppe(void) {
  uint8_t corps[TRAMES_AUDIO_CONFIG_TAILLE];
  uint8_t trame[TRAMES_ENTETE_TAILLE + TRAMES_AUDIO_CONFIG_TAILLE + 8];
  struct audio_config_vue config = {1, 48000, 256, 2, 0, 2048, 8};
  struct trame_vue vue;
  struct trame_decodeur d;
  size_t consommes = 0;

  verifier(audio_config_encoder(corps, sizeof corps, &config) ==
               TRAMES_AUDIO_CONFIG_TAILLE,
           "enveloppe : corps CONFIG");
  const int n = trame_encoder(trame, sizeof trame, TRAMES_AUDIO_TYPE_CONFIG, 0,
                              corps, TRAMES_AUDIO_CONFIG_TAILLE);
  verifier(n == TRAMES_ENTETE_TAILLE + TRAMES_AUDIO_CONFIG_TAILLE,
           "enveloppe : longueur de trame CONFIG");
  trame_decodeur_init(&d, TRAMES_MAX_FRAME_MAX);
  verifier(trame_decoder(&d, trame, (size_t)n, &vue, &consommes) == 1 &&
               consommes == (size_t)n &&
               vue.type == TRAMES_AUDIO_TYPE_CONFIG &&
               vue.longueur == TRAMES_AUDIO_CONFIG_TAILLE,
           "enveloppe : trame CONFIG décodée");
  {
    struct audio_config_vue lu;
    verifier(audio_config_decoder(vue.corps, vue.longueur, &lu) == 0 &&
                 lu.taux == 48000 && lu.capacite == 2048,
             "enveloppe : corps CONFIG relu");
  }

  // Troncature : l'enveloppe attend le reste du corps.
  trame_decodeur_init(&d, TRAMES_MAX_FRAME_MAX);
  verifier(trame_decoder(&d, trame, 8, &vue, &consommes) == 0 &&
               consommes == 8,
           "enveloppe : trame tronquée en attente");
  verifier(trame_decoder(&d, trame + 8, (size_t)n - 8, &vue, &consommes) == 1 &&
               consommes == (size_t)n - 8 &&
               vue.type == TRAMES_AUDIO_TYPE_CONFIG,
           "enveloppe : troncature complétée");

  // Longueur au-delà de max_frame : erreur de décodage.
  trame_decodeur_init(&d, TRAMES_AUDIO_CONFIG_TAILLE - 1);
  verifier(trame_decoder(&d, trame, (size_t)n, &vue, &consommes) == -1,
           "enveloppe : longueur au-delà de max_frame refusée");

  // Type inconnu : livré puis ignoré, sans erreur.
  {
    const uint8_t inconnu[2] = {0xAA, 0xBB};
    const int m = trame_encoder(trame, sizeof trame, 0x55, 0, inconnu, 2);
    trame_decodeur_init(&d, TRAMES_MAX_FRAME_MAX);
    verifier(trame_decoder(&d, trame, (size_t)m, &vue, &consommes) == 1 &&
                 vue.type == 0x55 && vue.longueur == 2 &&
                 octets_egaux(vue.corps, inconnu, 2),
             "enveloppe : type inconnu livré sans erreur");
  }

  // PING/PONG/BYE réutilisent l'enveloppe commune, corps vide.
  {
    const uint8_t types[3] = {TRAMES_AUDIO_TYPE_PING, TRAMES_AUDIO_TYPE_PONG,
                              TRAMES_AUDIO_TYPE_BYE};
    for (size_t i = 0; i < 3; ++i) {
      const int m = trame_encoder(trame, sizeof trame, types[i], 0, NULL, 0);
      trame_decodeur_init(&d, TRAMES_MAX_FRAME_MAX);
      verifier(trame_decoder(&d, trame, (size_t)m, &vue, &consommes) == 1 &&
                   vue.type == types[i] && vue.longueur == 0,
               "enveloppe : PING/PONG/BYE");
    }
  }
}

int main(void) {
  tester_poignee();
  tester_config();
  tester_ack();
  tester_device();
  tester_stop();
  tester_enveloppe();

  if (echecs == 0) {
    printf("-- trames audio macOS : OK\n");
    return 0;
  }
  printf("-- trames audio macOS : %d échec(s)\n", echecs);
  return 1;
}
