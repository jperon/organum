/* Fenêtre minimale sans bibliothèque du système : les protocoles Wayland et
 * X11 sont parlés directement sur la socket du serveur d'affichage. Wayland
 * est essayé d'abord (WAYLAND_DISPLAY), puis X11 (DISPLAY) ; ORGANUM_FENETRE
 * =x11|wayland impose le choix. Image au format 0x00RRGGBB, 32 bits/pixel. */
#ifndef FENETRE_H
#define FENETRE_H
#include <stdint.h>

typedef struct fenetre fenetre_t;

enum {
  FEN_RIEN,
  FEN_DEPLACEMENT,  // x, y
  FEN_BOUTON,       // bouton (1 gauche, 2 milieu, 3 droit, 4/5 molette), appui, x, y
  FEN_TOUCHE,       // code (keycode X), appui
  FEN_TAILLE,       // largeur, hauteur
  FEN_EXPOSITION,
  FEN_FERMETURE,
};

typedef struct {
  int type;
  int x, y;
  int bouton, appui, code;
  int largeur, hauteur;
} fenetre_ev_t;

// NULL si aucun serveur d'affichage local n'est joignable.
fenetre_t *fenetre_ouvrir(const char *titre, int largeur, int hauteur);
// Nom du protocole utilisé : "wayland" ou "x11".
const char *fenetre_protocole(fenetre_t *f);
int fenetre_fd(fenetre_t *f);
// Renvoie 1 et remplit *ev si un événement est disponible, 0 sinon ;
// attend au plus attente_ms (0 : n'attend pas, -1 : indéfiniment).
int fenetre_evenement(fenetre_t *f, fenetre_ev_t *ev, int attente_ms);
void fenetre_afficher(fenetre_t *f, const uint32_t *pixels, int largeur, int hauteur);
void fenetre_fermer(fenetre_t *f);

#endif
