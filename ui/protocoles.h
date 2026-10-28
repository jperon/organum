/* Déclarations des deux protocoles (même signature que fenetre.h). */
#ifndef PROTOCOLES_H
#define PROTOCOLES_H
#include "fenetre.h"
#define DECLARER(p) \
  typedef struct p p##_t; \
  p##_t *p##_ouvrir(const char *titre, int largeur, int hauteur); \
  int p##_fd(p##_t *x); \
  int p##_evenement(p##_t *x, fenetre_ev_t *ev, int attente_ms); \
  void p##_afficher(p##_t *x, const uint32_t *pixels, int largeur, int hauteur); \
  void p##_fermer(p##_t *x);
DECLARER(x11)
DECLARER(wl)
#undef DECLARER
#endif
