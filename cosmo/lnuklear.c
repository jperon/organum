/* Module Lua « nk » : interface graphique Nuklear (rendu logiciel rawfb)
 * dans une fenêtre Wayland ou X11 ouverte sans bibliothèque du système
 * (voir ui/fenetre.h). La logique de l'interface est écrite en Lua. */
#define NK_INCLUDE_FIXED_TYPES
#define NK_INCLUDE_STANDARD_IO
#define NK_INCLUDE_STANDARD_VARARGS
#define NK_INCLUDE_DEFAULT_ALLOCATOR
#define NK_INCLUDE_FONT_BAKING
#define NK_INCLUDE_DEFAULT_FONT
#define NK_INCLUDE_SOFTWARE_FONT
#define NK_IMPLEMENTATION
#define NK_RAWFB_IMPLEMENTATION

#include "libc/dce.h"
#include "third_party/lua/lauxlib.h"
#include "third_party/lua/lua.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "../ui/externe/nuklear.h"
#include "../ui/externe/nuklear_rawfb.h"
#include "../ui/fenetre.h"
#include "../ui/fenetre.c"
#include "../ui/x11.c"
#include "../ui/wayland.c"

static unsigned char police[1024 * 1024];  // atlas des glyphes (alpha)

typedef struct {
  fenetre_t *f;
  uint32_t *fb;
  struct rawfb_context *rf;
  struct nk_context *ctx;
  int l, h;
  int sale;
  char *ttf;  // police TrueType (copie), ou NULL : police bitmap de Nuklear
  size_t nttf;
} ui_t;

// Glyphes cuits : latin de base et Latin-1, œ, tirets, guillemets, points de suspension.
static const nk_rune kGlyphes[] = {0x0020, 0x00FF, 0x0152, 0x0153, 0x2013, 0x2014,
                                   0x2018, 0x201E, 0x2026, 0x2026, 0};

static int ui_gc(lua_State *L) {
  ui_t *u = luaL_checkudata(L, 1, "nk.ui");
  if (u->rf) {
    nk_font_atlas_clear(&u->rf->atlas);  // nk_rawfb_shutdown ne le libère pas
    nk_rawfb_shutdown(u->rf);
    u->rf = NULL;
  }
  if (u->f) { fenetre_fermer(u->f); u->f = NULL; }
  free(u->fb); u->fb = NULL;
  free(u->ttf); u->ttf = NULL;
  return 0;
}

// (Re)cuit la police par défaut à la taille donnée. Coûteux : à n'appeler
// qu'au changement de taille (mise à l'échelle de la fenêtre).
static int cuire_police(ui_t *u, int taille) {
  if (taille < 6) taille = 6;
  if (taille > 96) taille = 96;
  struct nk_font_atlas *atlas = &u->rf->atlas;
  nk_font_atlas_clear(atlas);
  nk_font_atlas_init_default(atlas);
  nk_font_atlas_begin(atlas);
  struct nk_font *fonte;
  if (u->ttf) {
    struct nk_font_config c = nk_font_config(taille);
    c.range = kGlyphes;
    c.oversample_h = 3, c.oversample_v = 1;  // lissage horizontal fin
    fonte = nk_font_atlas_add_from_memory(atlas, u->ttf, u->nttf, taille, &c);
  } else {
    fonte = nk_font_atlas_add_default(atlas, taille, NULL);
  }
  if (!fonte) return -1;
  int tl, th;
  const void *tex = nk_font_atlas_bake(atlas, &tl, &th, NK_FONT_ATLAS_ALPHA8);
  if (!tex || (size_t)tl * th > sizeof police) return -1;
  memcpy(police, tex, (size_t)tl * th);
  u->rf->font_tex.w = tl, u->rf->font_tex.h = th, u->rf->font_tex.pitch = tl;
  nk_font_atlas_end(atlas, nk_handle_ptr(NULL), NULL);
  nk_style_set_font(u->ctx, &fonte->handle);
  return 0;
}

static int lnk_ouvrir(lua_State *L) {
  const char *titre = luaL_checkstring(L, 1);
  int l = (int)luaL_checkinteger(L, 2);
  int h = (int)luaL_checkinteger(L, 3);
  int taille = (int)luaL_optinteger(L, 4, 20);
  size_t nttf = 0;
  const char *ttf = luaL_optlstring(L, 5, NULL, &nttf);  // police TrueType facultative
  fenetre_t *f = fenetre_ouvrir(titre, l, h);
  if (!f) { lua_pushnil(L); lua_pushstring(L, "pas de serveur d'affichage"); return 2; }
  ui_t *u = lua_newuserdata(L, sizeof(*u));
  memset(u, 0, sizeof(*u));
  fenetre_taille(f, &l, &h);
  u->f = f; u->l = l; u->h = h; u->sale = 1;
  if (ttf && nttf && (u->ttf = malloc(nttf))) memcpy(u->ttf, ttf, nttf), u->nttf = nttf;
  u->fb = calloc((size_t)l * h, 4);
  struct rawfb_pl pl = {4, 16, 8, 0, 24, 0, 0, 0, 8};
  u->rf = nk_rawfb_init(u->fb, police, l, h, l * 4, pl);
  u->ctx = &u->rf->ctx;
  // nk_rawfb_init cuit la police par défaut en 13 px : on la recuit à la
  // taille demandée, lisible sur une tablette.
  cuire_police(u, taille);
  // Jeux tirés, accouplements et combinaison courante bien visibles :
  // couleur d'accent pour les éléments actifs des boutons-bascule.
  struct nk_style_selectable *sel = &u->ctx->style.selectable;
  struct nk_color accent = nk_rgb(59, 130, 246), accent_clair = nk_rgb(96, 156, 250);
  sel->normal_active = nk_style_item_color(accent);
  sel->hover_active = nk_style_item_color(accent_clair);
  sel->pressed_active = nk_style_item_color(accent_clair);
  sel->text_normal_active = sel->text_hover_active = sel->text_pressed_active = nk_rgb(255, 255, 255);
  sel->normal = nk_style_item_color(nk_rgb(50, 50, 50));
  sel->hover = nk_style_item_color(nk_rgb(65, 65, 65));
  luaL_getmetatable(L, "nk.ui");
  lua_setmetatable(L, -2);
  return 1;
}

static int ui_police(lua_State *L) {
  ui_t *u = luaL_checkudata(L, 1, "nk.ui");
  lua_pushboolean(L, cuire_police(u, (int)luaL_checkinteger(L, 2)) == 0);
  return 1;
}

// ui:largeur_texte(s) → largeur en pixels avec la police courante.
static int ui_largeur_texte(lua_State *L) {
  ui_t *u = luaL_checkudata(L, 1, "nk.ui");
  size_t n;
  const char *s = luaL_checklstring(L, 2, &n);
  const struct nk_user_font *f = u->ctx->style.font;
  lua_pushnumber(L, f->width(f->userdata, f->height, s, (int)n));
  return 1;
}

static int ui_protocole(lua_State *L) {
  ui_t *u = luaL_checkudata(L, 1, "nk.ui");
  lua_pushstring(L, fenetre_protocole(u->f));
  return 1;
}

static int ui_evenements(lua_State *L) {
  ui_t *u = luaL_checkudata(L, 1, "nk.ui");
  int att = (int)luaL_checkinteger(L, 2);
  struct nk_context *ctx = u->ctx;
  nk_input_begin(ctx);
  int recu = 0, fin = 0;
  fenetre_ev_t ev;
  while (fenetre_evenement(u->f, &ev, recu ? 0 : att)) {
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
        u->l = ev.largeur; u->h = ev.hauteur;
        u->fb = realloc(u->fb, (size_t)u->l * u->h * 4);
        struct rawfb_pl pl = {4, 16, 8, 0, 24, 0, 0, 0, 8};
        nk_rawfb_resize_fb(u->rf, u->fb, u->l, u->h, u->l * 4, pl);
        break;
    }
    u->sale = 1;
    if (fin) break;
  }
  nk_input_end(ctx);
  lua_pushboolean(L, !fin);
  lua_pushboolean(L, u->sale);  // vrai s'il faut redessiner
  return 2;
}

static int ui_debut(lua_State *L) {
  ui_t *u = luaL_checkudata(L, 1, "nk.ui");
  const char *titre = luaL_checkstring(L, 2);
  float x = (float)luaL_checknumber(L, 3);
  float y = (float)luaL_checknumber(L, 4);
  float l = (float)luaL_checknumber(L, 5);
  float h = (float)luaL_checknumber(L, 6);
  // L'interface est calculée pour tenir dans la fenêtre : pas de défilement.
  nk_flags flags = (*titre ? NK_WINDOW_TITLE : 0) | NK_WINDOW_NO_SCROLLBAR;
  int r = nk_begin(u->ctx, titre, nk_rect(x, y, l, h), flags);
  lua_pushboolean(L, r);
  return 1;
}

static int ui_fin(lua_State *L) {
  ui_t *u = luaL_checkudata(L, 1, "nk.ui");
  nk_end(u->ctx);
  return 0;
}

static int ui_taille(lua_State *L) {
  ui_t *u = luaL_checkudata(L, 1, "nk.ui");
  lua_pushinteger(L, u->l);
  lua_pushinteger(L, u->h);
  return 2;
}

static int ui_ligne(lua_State *L) {
  ui_t *u = luaL_checkudata(L, 1, "nk.ui");
  float h = (float)luaL_checknumber(L, 2);
  int cols = (int)luaL_checkinteger(L, 3);
  nk_layout_row_dynamic(u->ctx, h, cols);
  return 0;
}

static int ui_texte(lua_State *L) {
  ui_t *u = luaL_checkudata(L, 1, "nk.ui");
  const char *s = luaL_checkstring(L, 2);
  nk_flags align = NK_TEXT_LEFT;
  if (lua_isstring(L, 3)) {
    const char *a = lua_tostring(L, 3);
    if (!strcmp(a, "centre")) align = NK_TEXT_CENTERED;
    else if (!strcmp(a, "droite")) align = NK_TEXT_RIGHT;
  }
  nk_label(u->ctx, s, align);
  return 0;
}

static int ui_bouton(lua_State *L) {
  ui_t *u = luaL_checkudata(L, 1, "nk.ui");
  const char *s = luaL_checkstring(L, 2);
  lua_pushboolean(L, nk_button_label(u->ctx, s));
  return 1;
}

static int ui_choix(lua_State *L) {
  ui_t *u = luaL_checkudata(L, 1, "nk.ui");
  const char *s = luaL_checkstring(L, 2);
  int actif = lua_toboolean(L, 3);
  nk_selectable_label(u->ctx, s, NK_TEXT_CENTERED, &actif);
  lua_pushboolean(L, actif);
  return 1;
}

static int ui_case(lua_State *L) {
  ui_t *u = luaL_checkudata(L, 1, "nk.ui");
  const char *s = luaL_checkstring(L, 2);
  int actif = lua_toboolean(L, 3);
  nk_checkbox_label(u->ctx, s, &actif);
  lua_pushboolean(L, actif);
  return 1;
}

static int ui_curseur(lua_State *L) {
  ui_t *u = luaL_checkudata(L, 1, "nk.ui");
  float v = (float)luaL_checknumber(L, 2);
  float mn = (float)luaL_checknumber(L, 3);
  float mx = (float)luaL_checknumber(L, 4);
  float pas = (float)luaL_checknumber(L, 5);
  nk_slider_float(u->ctx, mn, &v, mx, pas);
  lua_pushnumber(L, v);
  return 1;
}

static int ui_groupe_debut(lua_State *L) {
  ui_t *u = luaL_checkudata(L, 1, "nk.ui");
  const char *nom = luaL_checkstring(L, 2);
  lua_pushboolean(L, nk_group_begin(u->ctx, nom, NK_WINDOW_BORDER | NK_WINDOW_NO_SCROLLBAR));
  return 1;
}

static int ui_groupe_fin(lua_State *L) {
  ui_t *u = luaL_checkudata(L, 1, "nk.ui");
  nk_group_end(u->ctx);
  return 0;
}

static int ui_dessiner(lua_State *L) {
  ui_t *u = luaL_checkudata(L, 1, "nk.ui");
  unsigned char r = (unsigned char)luaL_checkinteger(L, 2);
  unsigned char g = (unsigned char)luaL_checkinteger(L, 3);
  unsigned char b = (unsigned char)luaL_checkinteger(L, 4);
  nk_rawfb_render(u->rf, nk_rgb(r, g, b), 1);
  fenetre_afficher(u->f, u->fb, u->l, u->h);
  u->sale = 0;
  return 0;
}

static const struct luaL_Reg nkfuncs[] = {
  {"ouvrir", lnk_ouvrir},
  {NULL, NULL}
};

static const struct luaL_Reg uifuncs[] = {
  {"protocole", ui_protocole},
  {"police", ui_police},
  {"largeur_texte", ui_largeur_texte},
  {"evenements", ui_evenements},
  {"debut", ui_debut},
  {"fin", ui_fin},
  {"taille", ui_taille},
  {"ligne", ui_ligne},
  {"texte", ui_texte},
  {"bouton", ui_bouton},
  {"choix", ui_choix},
  {"case", ui_case},
  {"curseur", ui_curseur},
  {"groupe_debut", ui_groupe_debut},
  {"groupe_fin", ui_groupe_fin},
  {"dessiner", ui_dessiner},
  {NULL, NULL}
};

int luaopen_nk(lua_State *L) {
  if (luaL_newmetatable(L, "nk.ui")) {
    lua_pushcfunction(L, ui_gc);
    lua_setfield(L, -2, "__gc");
    luaL_newlib(L, uifuncs);
    lua_setfield(L, -2, "__index");
  }
  lua_pop(L, 1);
  luaL_newlib(L, nkfuncs);
  return 1;
}

