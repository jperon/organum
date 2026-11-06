// Filtre de transposition (cosmo/transposition.h) : décalage, bornes,
// changement pendant une note tenue, vélocité nulle, canaux indépendants.
#include "transposition.h"

#include <stdio.h>

static int echecs;

static void verifier(int condition, const char *message) {
  if (!condition) {
    printf("ÉCHEC : %s\n", message);
    ++echecs;
  }
}

static int filtrer(struct transposition_etat *t, int tr, unsigned char a,
                   unsigned char b, unsigned char c, unsigned char *sortie) {
  unsigned char entree[3] = {a, b, c};
  return transposition_filtrer(t, tr, entree, sortie);
}

int main(void) {
  struct transposition_etat t;
  unsigned char s[3];

  // Transposition nulle : la note traverse sans changement.
  transposition_reinitialiser(&t);
  verifier(filtrer(&t, 0, 0x90, 60, 100, s) == 1, "appui à 0 : envoyé");
  verifier(s[0] == 0x90 && s[1] == 60 && s[2] == 100,
           "appui à 0 : mêmes octets");
  verifier(filtrer(&t, 0, 0x80, 60, 0, s) == 1, "relâchement à 0 : envoyé");
  verifier(s[0] == 0x80 && s[1] == 60, "relâchement à 0 : même note");

  // Décalage vers le haut puis vers le bas.
  transposition_reinitialiser(&t);
  verifier(filtrer(&t, 12, 0x90, 60, 100, s) == 1, "+12 : appui envoyé");
  verifier(s[1] == 72, "+12 : note décalée");
  verifier(filtrer(&t, 12, 0x80, 60, 0, s) == 1, "+12 : relâchement envoyé");
  verifier(s[1] == 72, "+12 : relâchement sur la note décalée");

  transposition_reinitialiser(&t);
  verifier(filtrer(&t, -12, 0x90, 60, 100, s) == 1, "-12 : appui envoyé");
  verifier(s[1] == 48, "-12 : note décalée");

  // Une note tenue garde sa hauteur si la transposition change.
  transposition_reinitialiser(&t);
  verifier(filtrer(&t, 3, 0x90, 60, 100, s) == 1, "tenue : appui");
  verifier(s[1] == 63, "tenue : +3");
  verifier(filtrer(&t, -5, 0x80, 60, 0, s) == 1, "tenue : relâchement");
  verifier(s[1] == 63, "tenue : relâchement garde 63 malgré -5");
  // La table est libérée : un second relâchement est ignoré.
  verifier(filtrer(&t, -5, 0x80, 60, 0, s) == 0,
           "double relâchement : ignoré");

  // Vélocité nulle sur 0x9n : c'est un relâchement.
  transposition_reinitialiser(&t);
  verifier(filtrer(&t, 7, 0x90, 60, 90, s) == 1, "vélocité 0 : appui");
  verifier(s[1] == 67, "vélocité 0 : appui décalé");
  verifier(filtrer(&t, 7, 0x90, 60, 0, s) == 1,
           "vélocité 0 : relâchement envoyé");
  verifier(s[1] == 67, "vélocité 0 : relâchement sur la note retenue");

  // Hors 0..127 après décalage : ni appui, ni relâchement.
  transposition_reinitialiser(&t);
  verifier(filtrer(&t, 12, 0x90, 120, 100, s) == 0,
           "hors étendue haut : appui ignoré");
  verifier(filtrer(&t, 12, 0x80, 120, 0, s) == 0,
           "hors étendue haut : relâchement ignoré");
  transposition_reinitialiser(&t);
  verifier(filtrer(&t, -12, 0x90, 5, 100, s) == 0,
           "hors étendue bas : appui ignoré");
  verifier(filtrer(&t, -12, 0x80, 5, 0, s) == 0,
           "hors étendue bas : relâchement ignoré");
  // La table n'a pas retenu la note rejetée : même avec une transposition
  // redevenue nulle, le relâchement reste ignoré.
  verifier(filtrer(&t, 0, 0x80, 5, 0, s) == 0,
           "note rejetée : aucun relâchement retenu");

  // Canaux indépendants, y compris pour la même note.
  transposition_reinitialiser(&t);
  verifier(filtrer(&t, 5, 0x90, 60, 100, s) == 1, "canal 0 : appui");
  verifier(s[1] == 65, "canal 0 : +5");
  verifier(filtrer(&t, 5, 0x91, 60, 100, s) == 1, "canal 1 : appui");
  verifier(s[1] == 65 && s[0] == 0x91, "canal 1 : +5");
  verifier(filtrer(&t, -2, 0x81, 60, 0, s) == 1, "canal 1 : relâchement");
  verifier(s[1] == 65 && s[0] == 0x81, "canal 1 : garde 65");
  verifier(filtrer(&t, -2, 0x90, 60, 0, s) == 1, "canal 0 : relâchement");
  verifier(s[1] == 65 && s[0] == 0x90, "canal 0 : garde 65");

  // Pression polyphonique : décalée via la table si la note est tenue,
  // inchangée sinon.
  transposition_reinitialiser(&t);
  verifier(filtrer(&t, 4, 0x90, 60, 100, s) == 1, "pression : appui");
  verifier(filtrer(&t, 4, 0xA0, 60, 50, s) == 1, "pression : tenue envoyée");
  verifier(s[0] == 0xA0 && s[1] == 64 && s[2] == 50,
           "pression : note tenue décalée");
  verifier(filtrer(&t, 4, 0xA0, 55, 50, s) == 1,
           "pression : note non tenue envoyée");
  verifier(s[1] == 55, "pression : note non tenue inchangée");

  // Autres messages : inchangés.
  transposition_reinitialiser(&t);
  verifier(filtrer(&t, 9, 0xB0, 7, 100, s) == 1, "CC : envoyé");
  verifier(s[0] == 0xB0 && s[1] == 7 && s[2] == 100, "CC : inchangé");
  verifier(filtrer(&t, 9, 0xC0, 5, 0, s) == 1, "program change : envoyé");
  verifier(s[0] == 0xC0 && s[1] == 5, "program change : inchangé");
  verifier(filtrer(&t, 9, 0xF0, 0x7E, 0x7F, s) == 1, "SysEx : envoyé");
  verifier(s[0] == 0xF0 && s[1] == 0x7E, "SysEx : inchangé");

  // Réinitialisation (panique, recréation) : plus aucune note retenue.
  transposition_reinitialiser(&t);
  verifier(filtrer(&t, 2, 0x90, 60, 100, s) == 1, "réinit : appui");
  transposition_reinitialiser(&t);
  verifier(filtrer(&t, 2, 0x80, 60, 0, s) == 0,
           "réinit : relâchement ignoré, aucune note bloquée");

  if (echecs == 0) {
    printf("-- transposition : OK\n");
    return 0;
  }
  printf("-- transposition : %d échec(s)\n", echecs);
  return 1;
}
