// Codec du protocole MIDI macOS (plateforme/macos/trames_midi.h) : poignée de
// main, trames, alimentation octet par octet, bornes, DEVICE_LIST et chemin
// de socket.
#include "../macos/trames_midi.h"

#include <stdio.h>

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

// Décode une poignée de main et vérifie les champs attendus.
static void verifier_poignee(const uint8_t *p, int attendu_code,
                             uint8_t attendu_statut,
                             uint16_t attendu_max_frame,
                             const char *message) {
  struct poignee_vue vue;
  const int code = poignee_decoder(p, &vue);
  verifier(code == attendu_code, message);
  verifier(vue.statut == attendu_statut, message);
  verifier(vue.max_frame == attendu_max_frame, message);
}

int main(void) {
  uint8_t poignee[TRAMES_MIDI_POIGNEE_TAILLE];
  uint8_t tampon[256];
  struct trame_vue vue;
  size_t consommes = 0;

  // --- Poignée de main ----------------------------------------------------
  poignee_encoder(poignee, TRAMES_MIDI_STATUT_OK, 1024);
  verifier(octets_egaux(poignee, (const uint8_t *)"OMID", 4),
           "poignée : magic OMID");
  verifier(poignee[4] == 1 && poignee[5] == 0, "poignée : version et statut");
  verifier(poignee[6] == 0x00 && poignee[7] == 0x04,
           "poignée : max_frame en petit-boutiste");
  verifier_poignee(poignee, 1, TRAMES_MIDI_STATUT_OK, 1024,
                   "poignée : aller-retour accepté");

  // Statut non nul : poignée valide mais refusée (0), champs lisibles.
  poignee_encoder(poignee, TRAMES_MIDI_STATUT_VERSION, 512);
  verifier_poignee(poignee, 0, TRAMES_MIDI_STATUT_VERSION, 512,
                   "poignée : statut de refus lu");

  // Magic invalide.
  poignee_encoder(poignee, TRAMES_MIDI_STATUT_OK, 256);
  poignee[2] = 'X';
  verifier_poignee(poignee, -1, TRAMES_MIDI_STATUT_OK, 256,
                   "poignée : magic invalide refusé");

  // Version inconnue.
  poignee_encoder(poignee, TRAMES_MIDI_STATUT_OK, 256);
  poignee[4] = 2;
  verifier_poignee(poignee, -2, TRAMES_MIDI_STATUT_OK, 256,
                   "poignée : version 2 refusée");
  poignee[4] = 0;
  verifier_poignee(poignee, -2, TRAMES_MIDI_STATUT_OK, 256,
                   "poignée : version 0 refusée");

  // max_frame hors bornes 64..8192.
  poignee_encoder(poignee, TRAMES_MIDI_STATUT_OK, TRAMES_MIDI_MAX_FRAME_MIN - 1);
  verifier_poignee(poignee, -3, TRAMES_MIDI_STATUT_OK,
                   TRAMES_MIDI_MAX_FRAME_MIN - 1,
                   "poignée : max_frame 63 refusé");
  poignee_encoder(poignee, TRAMES_MIDI_STATUT_OK, 9000);
  verifier_poignee(poignee, -3, TRAMES_MIDI_STATUT_OK, 9000,
                   "poignée : max_frame 9000 refusé");
  poignee_encoder(poignee, TRAMES_MIDI_STATUT_OK, TRAMES_MIDI_MAX_FRAME_MIN);
  verifier_poignee(poignee, 1, TRAMES_MIDI_STATUT_OK, TRAMES_MIDI_MAX_FRAME_MIN,
                   "poignée : max_frame 64 accepté");
  poignee_encoder(poignee, TRAMES_MIDI_STATUT_OK, TRAMES_MIDI_MAX_FRAME_MAX);
  verifier_poignee(poignee, 1, TRAMES_MIDI_STATUT_OK, TRAMES_MIDI_MAX_FRAME_MAX,
                   "poignée : max_frame 8192 accepté");

  // --- Trame aller-retour -------------------------------------------------
  {
    struct trame_decodeur d;
    const uint8_t corps[3] = {0x90, 60, 100};
    const int n = trame_encoder(tampon, sizeof tampon, TRAMES_MIDI_TYPE_MIDI, 0,
                                corps, 3);
    verifier(n == 7, "trame : longueur encodée");
    verifier(tampon[0] == TRAMES_MIDI_TYPE_MIDI && tampon[1] == 0 &&
                 tampon[2] == 3 && tampon[3] == 0,
             "trame : en-tête type, flags, longueur LE16");
    trame_decodeur_init(&d, 8192);
    verifier(trame_decoder(&d, tampon, (size_t)n, &vue, &consommes) == 1,
             "trame : décodée d'un seul appel");
    verifier(consommes == 7, "trame : tous les octets consommés");
    verifier(vue.type == TRAMES_MIDI_TYPE_MIDI && vue.flags == 0 &&
                 vue.longueur == 3,
             "trame : champs décodés");
    verifier(octets_egaux(vue.corps, corps, 3), "trame : corps intact");
    verifier(trame_midi_valide(vue.corps, vue.longueur),
             "trame : corps MIDI valide");
  }

  // Capacité insuffisante à l'encodage.
  {
    const uint8_t corps[3] = {0x90, 60, 100};
    verifier(trame_encoder(tampon, 6, TRAMES_MIDI_TYPE_MIDI, 0, corps, 3) == -1,
             "encodeur : capacité insuffisante refusée");
  }

  // --- Alimentation octet par octet ---------------------------------------
  {
    struct trame_decodeur d;
    const uint8_t corps[3] = {0xB0, 7, 127};
    const int n = trame_encoder(tampon, sizeof tampon, TRAMES_MIDI_TYPE_MIDI,
                                0x02, corps, 3);
    trame_decodeur_init(&d, 8192);
    int prete = 0;
    for (int i = 0; i < n; ++i) {
      const int r = trame_decoder(&d, tampon + i, 1, &vue, &consommes);
      if (i < n - 1)
        verifier(r == 0 && consommes == 1,
                 "octet par octet : besoin de plus");
      else
        verifier(r == 1 && consommes == 1,
                 "octet par octet : prête au dernier octet");
      if (r == 1) prete = 1;
    }
    verifier(prete, "octet par octet : trame obtenue");
    verifier(vue.type == TRAMES_MIDI_TYPE_MIDI && vue.flags == 0x02 &&
                 vue.longueur == 3 &&
                 octets_egaux(vue.corps, corps, 3),
             "octet par octet : contenu intact");
  }

  // --- Deux trames dans un seul tampon ------------------------------------
  {
    struct trame_decodeur d;
    const uint8_t c1[3] = {0x90, 60, 100};
    const uint8_t c2[2] = {0xC0, 5};
    int n = trame_encoder(tampon, sizeof tampon, TRAMES_MIDI_TYPE_MIDI, 0, c1, 3);
    const int n1 = n;
    n += trame_encoder(tampon + n, sizeof tampon - (size_t)n,
                       TRAMES_MIDI_TYPE_MIDI, 0, c2, 2);
    trame_decodeur_init(&d, 8192);
    verifier(trame_decoder(&d, tampon, (size_t)n, &vue, &consommes) == 1 &&
                 consommes == (size_t)n1 && vue.longueur == 3 &&
                 octets_egaux(vue.corps, c1, 3),
             "deux trames : première");
    verifier(trame_decoder(&d, tampon + n1, (size_t)(n - n1), &vue,
                           &consommes) == 1 &&
                 consommes == 6 && vue.longueur == 2 &&
                 octets_egaux(vue.corps, c2, 2),
             "deux trames : seconde");
  }

  // --- Longueur au-delà de max_frame --------------------------------------
  {
    struct trame_decodeur d;
    const uint8_t entete[4] = {TRAMES_MIDI_TYPE_MIDI, 0, 65, 0};
    trame_decodeur_init(&d, 64);
    verifier(trame_decoder(&d, entete, 4, &vue, &consommes) == -1,
             "max_frame : longueur 65 refusée");
    trame_decodeur_init(&d, 65);
    verifier(trame_decoder(&d, entete, 4, &vue, &consommes) == 0,
             "max_frame : longueur 65 acceptée à 65");
  }

  // --- Type inconnu : décodé puis ignoré par l'appelant -------------------
  {
    struct trame_decodeur d;
    const uint8_t corps[2] = {0xAA, 0xBB};
    const int n = trame_encoder(tampon, sizeof tampon, 0x55, 0, corps, 2);
    trame_decodeur_init(&d, 8192);
    verifier(trame_decoder(&d, tampon, (size_t)n, &vue, &consommes) == 1 &&
                 vue.type == 0x55 && vue.longueur == 2 &&
                 octets_egaux(vue.corps, corps, 2),
             "type inconnu : trame livrée sans erreur");
  }

  // --- Validation du corps MIDI -------------------------------------------
  {
    const uint8_t zero[1] = {0};
    const uint8_t sysex[3] = {0xF0, 0x7E, 0x7F};
    const uint8_t note_on[3] = {0x90, 60, 100};
    const uint8_t program[2] = {0xC0, 5};
    const uint8_t program_trop_long[3] = {0xC0, 5, 0};
    const uint8_t note_on_court[2] = {0x90, 60};
    verifier(!trame_midi_valide(zero, 0), "MIDI : longueur 0 rejetée");
    verifier(!trame_midi_valide(sysex, 3), "MIDI : statut 0xF0 rejeté");
    verifier(!trame_midi_valide(note_on, 4), "MIDI : longueur 4 rejetée");
    verifier(!trame_midi_valide(note_on_court, 2),
             "MIDI : note on de 2 octets rejeté");
    verifier(!trame_midi_valide(program_trop_long, 3),
             "MIDI : program change de 3 octets rejeté");
    verifier(trame_midi_valide(note_on, 3), "MIDI : note on valide");
    verifier(trame_midi_valide(program, 2), "MIDI : program change valide");
  }

  // --- DEVICE_LIST --------------------------------------------------------
  {
    struct peripherique_vue vues[TRAMES_MIDI_PERIPHERIQUES_MAX];

    // Aucune entrée.
    {
      const uint8_t corps[1] = {0};
      verifier(peripheriques_parser(corps, 1, vues,
                                    TRAMES_MIDI_PERIPHERIQUES_MAX) == 0,
               "DEVICE_LIST : zéro entrée");
    }

    // Une entrée avec nom.
    {
      const uint8_t corps[] = {1, 7, TRAMES_MIDI_CAPACITE_SOURCE, 4, 'O', 'r',
                               'g', 'a'};
      const int n = peripheriques_parser(corps, (uint16_t)sizeof corps, vues,
                                         TRAMES_MIDI_PERIPHERIQUES_MAX);
      verifier(n == 1, "DEVICE_LIST : une entrée");
      verifier(vues[0].id == 7 &&
                   vues[0].capacites == TRAMES_MIDI_CAPACITE_SOURCE &&
                   vues[0].nom_len == 4 && octets_egaux(vues[0].nom,
                                                        (const uint8_t *)"Orga",
                                                        4),
               "DEVICE_LIST : champs de l'entrée");
    }

    // 32 entrées avec des noms vides.
    {
      uint8_t corps[1 + TRAMES_MIDI_PERIPHERIQUES_MAX * 3];
      size_t i = 0;
      corps[i++] = TRAMES_MIDI_PERIPHERIQUES_MAX;
      for (int k = 0; k < TRAMES_MIDI_PERIPHERIQUES_MAX; ++k) {
        corps[i++] = (uint8_t)k;
        corps[i++] = TRAMES_MIDI_CAPACITE_DESTINATION;
        corps[i++] = 0;
      }
      const int n = peripheriques_parser(corps, (uint16_t)i, vues,
                                         TRAMES_MIDI_PERIPHERIQUES_MAX);
      verifier(n == TRAMES_MIDI_PERIPHERIQUES_MAX,
               "DEVICE_LIST : 32 entrées");
      verifier(vues[31].id == 31, "DEVICE_LIST : dernière entrée");
    }

    // n menti : seules les entrées complètes sont retenues.
    {
      const uint8_t corps[] = {5, 1, 1, 0, 2, 2, 0};
      const int n = peripheriques_parser(corps, (uint16_t)sizeof corps, vues,
                                         TRAMES_MIDI_PERIPHERIQUES_MAX);
      verifier(n == 2, "DEVICE_LIST : n menti tronqué aux entrées complètes");
      verifier(vues[0].id == 1 && vues[1].id == 2,
               "DEVICE_LIST : entrées tronquées correctes");
    }

    // n menti au milieu d'un nom.
    {
      const uint8_t corps[] = {2, 1, 1, 4, 'a', 'b', 'c', 2, 2, 0};
      const int n = peripheriques_parser(corps, (uint16_t)sizeof corps, vues,
                                         TRAMES_MIDI_PERIPHERIQUES_MAX);
      verifier(n == 1, "DEVICE_LIST : nom incomplet tronqué");
    }

    // Nom de 64 octets : refus explicite.
    {
      uint8_t corps[1 + 3 + 64];
      corps[0] = 1;
      corps[1] = 1;
      corps[2] = 1;
      corps[3] = 64;
      memset(corps + 4, 'x', 64);
      verifier(peripheriques_parser(corps, (uint16_t)sizeof corps, vues,
                                    TRAMES_MIDI_PERIPHERIQUES_MAX) == -1,
               "DEVICE_LIST : nom de 64 octets refusé");
    }

    // Corps vide.
    verifier(peripheriques_parser((const uint8_t *)"", 0, vues,
                                  TRAMES_MIDI_PERIPHERIQUES_MAX) == -1,
             "DEVICE_LIST : corps vide refusé");

    // Capacité de rangement inférieure à n.
    {
      const uint8_t corps[] = {3, 1, 1, 0, 2, 2, 0, 3, 3, 0};
      verifier(peripheriques_parser(corps, (uint16_t)sizeof corps, vues, 2) ==
                   2,
               "DEVICE_LIST : rangement plafonné à la capacité");
    }
  }

  // --- Chemin de la socket ------------------------------------------------
  {
    char chemin[TRAMES_MIDI_SUN_PATH_MAX];

    verifier(trame_chemin_socket("/tmp/prioritaire.sock", "/tmp/autre", 501,
                                 chemin, sizeof chemin) == 0 &&
                 strcmp(chemin, "/tmp/prioritaire.sock") == 0,
             "chemin : ORGANUM_MIDI_SOCKET prioritaire");

    verifier(trame_chemin_socket("", "/tmp/autre", 501, chemin,
                                 sizeof chemin) == 0 &&
                 strcmp(chemin, "/tmp/autre/organum-midi-501.sock") == 0,
             "chemin : variable vide ignorée, TMPDIR utilisé");

    verifier(trame_chemin_socket(NULL, "/tmp/dossier avec espace", 501, chemin,
                                 sizeof chemin) == 0 &&
                 strcmp(chemin,
                        "/tmp/dossier avec espace/organum-midi-501.sock") == 0,
             "chemin : TMPDIR avec espace conservé");

    verifier(trame_chemin_socket(NULL, NULL, 501, chemin, sizeof chemin) == 0 &&
                 strcmp(chemin, "/tmp/organum-midi-501.sock") == 0,
             "chemin : repli /tmp");

    verifier(trame_chemin_socket(NULL, "", 501, chemin, sizeof chemin) == 0 &&
                 strcmp(chemin, "/tmp/organum-midi-501.sock") == 0,
             "chemin : TMPDIR vide, repli /tmp");

    // Une barre finale dans TMPDIR n'est pas doublée.
    verifier(trame_chemin_socket(NULL, "/tmp/dossier/", 501, chemin,
                                 sizeof chemin) == 0 &&
                 strcmp(chemin, "/tmp/dossier/organum-midi-501.sock") == 0,
             "chemin : barre finale de TMPDIR non doublée");

    // Dépassement : refus explicite, jamais de troncature.
    {
      char long_env[TRAMES_MIDI_SUN_PATH_MAX + 8];
      memset(long_env, 'a', sizeof long_env - 1);
      long_env[sizeof long_env - 1] = '\0';
      verifier(trame_chemin_socket(long_env, NULL, 501, chemin,
                                   sizeof chemin) == -1,
               "chemin : ORGANUM_MIDI_SOCKET trop long refusé");
    }
    {
      char long_tmpdir[TRAMES_MIDI_SUN_PATH_MAX];
      memset(long_tmpdir, 'b', sizeof long_tmpdir - 1);
      long_tmpdir[sizeof long_tmpdir - 1] = '\0';
      verifier(trame_chemin_socket(NULL, long_tmpdir, 501, chemin,
                                   sizeof chemin) == -1,
               "chemin : TMPDIR trop long refusé");
    }
    verifier(trame_chemin_socket("/tmp/court.sock", NULL, 501, chemin, 8) == -1,
             "chemin : capacité de sortie insuffisante refusée");
  }

  if (echecs == 0) {
    printf("-- trames MIDI macOS : OK\n");
    return 0;
  }
  printf("-- trames MIDI macOS : %d échec(s)\n", echecs);
  return 1;
}
