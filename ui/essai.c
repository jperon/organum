/* Prototype : fenêtre X11 + Nuklear (rendu logiciel rawfb). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define NK_INCLUDE_FIXED_TYPES
#define NK_INCLUDE_STANDARD_IO
#define NK_INCLUDE_STANDARD_VARARGS
#define NK_INCLUDE_DEFAULT_ALLOCATOR
#define NK_INCLUDE_FONT_BAKING
#define NK_INCLUDE_DEFAULT_FONT
#define NK_INCLUDE_SOFTWARE_FONT
#define NK_IMPLEMENTATION
#define NK_RAWFB_IMPLEMENTATION
#include "externe/nuklear.h"
#include "externe/nuklear_rawfb.h"
#include "fenetre.h"

static unsigned char police[512 * 512];

int main(void) {
  int l = 480, h = 360;
  fenetre_t *x = fenetre_ouvrir("organum (essai)", l, h);
  if (!x) {
    fprintf(stderr, "pas de serveur d.affichage\n");
    return 1;
  }
  uint32_t *fb = calloc(l * h, 4);
  struct rawfb_pl pl = {4, 16, 8, 0, 24, 0, 0, 0, 8};
  struct rawfb_context *rf = nk_rawfb_init(fb, police, l, h, l * 4, pl);
  struct nk_context *ctx = &rf->ctx;
  float volume = 0.5f;
  int jeux[4] = {0}, fin = 0, sale = 1;
  while (!fin) {
    fenetre_ev_t ev;
    nk_input_begin(ctx);
    int recu = 0;
    while (fenetre_evenement(x, &ev, recu ? 0 : 50)) {
      recu = 1;
      switch (ev.type) {
        case FEN_FERMETURE: fin = 1; break;
        case FEN_DEPLACEMENT: nk_input_motion(ctx, ev.x, ev.y); break;
        case FEN_BOUTON:
          if (ev.bouton == 1) nk_input_button(ctx, NK_BUTTON_LEFT, ev.x, ev.y, ev.appui);
          else if (ev.bouton == 4 && ev.appui) nk_input_scroll(ctx, nk_vec2(0, 1));
          else if (ev.bouton == 5 && ev.appui) nk_input_scroll(ctx, nk_vec2(0, -1));
          break;
        case FEN_TAILLE:
          l = ev.largeur, h = ev.hauteur;
          fb = realloc(fb, (size_t)l * h * 4);
          nk_rawfb_resize_fb(rf, fb, l, h, l * 4, pl);
          break;
      }
      sale = 1;
    }
    nk_input_end(ctx);
    if (!sale) continue;
    sale = 0;
    if (nk_begin(ctx, "Orgue", nk_rect(0, 0, l, h), NK_WINDOW_TITLE)) {
      nk_layout_row_dynamic(ctx, 40, 4);
      const char *noms[4] = {"Bourdon 8", "Prestant 4", "Doublette 2", "Trompette 8"};
      for (int i = 0; i < 4; ++i)
        if (nk_selectable_label(ctx, noms[i], NK_TEXT_CENTERED, &jeux[i]))
          printf("%s : %d\n", noms[i], jeux[i]);
      nk_layout_row_dynamic(ctx, 30, 1);
      nk_label(ctx, "Volume", NK_TEXT_LEFT);
      nk_slider_float(ctx, 0, &volume, 1, 0.01f);
      nk_layout_row_dynamic(ctx, 40, 1);
      if (nk_button_label(ctx, "Panique")) printf("panique\n");
    }
    nk_end(ctx);
    nk_rawfb_render(rf, nk_rgb(30, 30, 30), 1);
    fenetre_afficher(x, fb, l, h);
    fflush(stdout);
  }
  nk_rawfb_shutdown(rf);
  fenetre_fermer(x);
  return 0;
}
