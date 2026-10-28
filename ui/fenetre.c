/* Choix du protocole d'affichage : Wayland d'abord, X11 ensuite. */
#include <stdlib.h>
#include <string.h>

#include "protocoles.h"

struct fenetre {
  int wayland;
  void *p;
};

fenetre_t *fenetre_ouvrir(const char *titre, int largeur, int hauteur) {
  const char *impose = getenv("ORGANUM_FENETRE");
  fenetre_t f = {0};
  if (!impose || !strcmp(impose, "wayland")) {
    f.p = wl_ouvrir(titre, largeur, hauteur);
    f.wayland = f.p != NULL;
  }
  if (!f.p && (!impose || !strcmp(impose, "x11"))) f.p = x11_ouvrir(titre, largeur, hauteur);
  if (!f.p) return NULL;
  fenetre_t *r = malloc(sizeof *r);
  *r = f;
  return r;
}

const char *fenetre_protocole(fenetre_t *f) { return f->wayland ? "wayland" : "x11"; }

#define AIGUILLER(appel, ...) (f->wayland ? wl_##appel(f->p, __VA_ARGS__) : x11_##appel(f->p, __VA_ARGS__))

int fenetre_fd(fenetre_t *f) { return f->wayland ? wl_fd(f->p) : x11_fd(f->p); }
void fenetre_taille(fenetre_t *f, int *l, int *h) { AIGUILLER(taille, l, h); }
int fenetre_evenement(fenetre_t *f, fenetre_ev_t *ev, int attente_ms) { return AIGUILLER(evenement, ev, attente_ms); }
void fenetre_afficher(fenetre_t *f, const uint32_t *p, int l, int h) { AIGUILLER(afficher, p, l, h); }

void fenetre_fermer(fenetre_t *f) {
  if (!f) return;
  if (f->wayland) wl_fermer(f->p);
  else x11_fermer(f->p);
  free(f);
}
