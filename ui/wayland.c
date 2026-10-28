/* Client Wayland minimal, sans libwayland : le protocole filaire est parlé
 * directement sur la socket du compositeur ($XDG_RUNTIME_DIR/$WAYLAND_DISPLAY).
 * Interfaces : wl_compositor, wl_shm (tampons en mémoire partagée), xdg_wm_base
 * (fenêtre), wl_seat (pointeur, tactile), et zxdg_decoration_manager_v1 si le
 * compositeur sait dessiner les bordures (sinon la fenêtre en est dépourvue).
 *
 * Format d'un message : u32 objet, u32 (taille << 16 | opcode), arguments
 * alignés sur 32 bits ; les descripteurs passent en données annexes
 * (SCM_RIGHTS). */
#include <errno.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include "protocoles.h"

#define NTAMPONS 2

typedef struct {
  uint32_t id, pool;
  uint32_t *pixels;
  size_t octets;
  int largeur, hauteur, occupe;
} tampon_t;

struct wl {
  int fd;
  uint32_t suivant;  // prochain identifiant d'objet
  // Globaux
  uint32_t registre, compositeur, shm, wm, siege, decorations;
  uint32_t version_siege;
  // Objets de la fenêtre
  uint32_t surface, xdg_surface, toplevel, pointeur, tactile, synchro;
  int configure, synchro_ok, ferme;
  int largeur, hauteur, l_attente, h_attente;
  int px, py;  // dernière position du pointeur
  int doigt;   // identifiant du doigt suivi (-1 : aucun)
  tampon_t tampons[NTAMPONS];
  // File d'événements prêts à rendre
  fenetre_ev_t file[64];
  int ftete, fqueue;
  // Tampon de lecture
  uint8_t lu[8192];
  int debut, fin;
};

/* --- Émission --- */

typedef struct { uint32_t m[64]; int n; int fd; } msg_t;

static void debut(msg_t *m, uint32_t objet, uint16_t op) {
  m->n = 2, m->fd = -1;
  m->m[0] = objet, m->m[1] = op;
}
static void u(msg_t *m, uint32_t v) { m->m[m->n++] = v; }
static void chaine(msg_t *m, const char *s) {
  uint32_t n = strlen(s) + 1;
  u(m, n);
  memset(&m->m[m->n], 0, (n + 3) & ~3u);
  memcpy(&m->m[m->n], s, n);
  m->n += (n + 3) / 4;
}

static int envoyer(struct wl *w, msg_t *m) {
  m->m[1] |= (uint32_t)(m->n * 4) << 16;
  struct iovec io = {m->m, m->n * 4};
  union { char b[CMSG_SPACE(sizeof(int))]; struct cmsghdr a; } annexe;
  struct msghdr h = {.msg_iov = &io, .msg_iovlen = 1};
  if (m->fd >= 0) {
    h.msg_control = annexe.b, h.msg_controllen = sizeof annexe.b;
    struct cmsghdr *c = CMSG_FIRSTHDR(&h);
    c->cmsg_level = SOL_SOCKET, c->cmsg_type = SCM_RIGHTS;
    c->cmsg_len = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(c), &m->fd, sizeof(int));
  }
  for (;;) {
    ssize_t k = sendmsg(w->fd, &h, MSG_NOSIGNAL);
    if (k < 0 && errno == EINTR) continue;
    return k == m->n * 4 ? 0 : -1;
  }
}

static uint32_t nouvel_objet(struct wl *w) { return w->suivant++; }

static uint32_t lier(struct wl *w, uint32_t nom, const char *interface, uint32_t version) {
  msg_t m;
  uint32_t id = nouvel_objet(w);
  debut(&m, w->registre, 0);  // wl_registry.bind
  u(&m, nom), chaine(&m, interface), u(&m, version), u(&m, id);
  envoyer(w, &m);
  return id;
}

static void synchroniser(struct wl *w) {
  msg_t m;
  w->synchro = nouvel_objet(w), w->synchro_ok = 0;
  debut(&m, 1, 0), u(&m, w->synchro);  // wl_display.sync
  envoyer(w, &m);
}

/* --- Réception --- */

static void pousser(struct wl *w, fenetre_ev_t ev) {
  if (w->fqueue - w->ftete < 64) w->file[w->fqueue++ % 64] = ev;
}

// Lit ce qui est disponible sur la socket ; les descripteurs reçus (aucun
// attendu : on ne demande pas le clavier) sont refermés.
static int remplir(struct wl *w) {
  if (w->debut > 0) {
    memmove(w->lu, w->lu + w->debut, w->fin - w->debut);
    w->fin -= w->debut, w->debut = 0;
  }
  struct iovec io = {w->lu + w->fin, sizeof w->lu - w->fin};
  union { char b[CMSG_SPACE(8 * sizeof(int))]; struct cmsghdr a; } annexe;
  struct msghdr h = {.msg_iov = &io, .msg_iovlen = 1, .msg_control = annexe.b, .msg_controllen = sizeof annexe.b};
  ssize_t k;
  do k = recvmsg(w->fd, &h, 0);
  while (k < 0 && errno == EINTR);
  if (k <= 0) return -1;
  for (struct cmsghdr *c = CMSG_FIRSTHDR(&h); c; c = CMSG_NXTHDR(&h, c))
    if (c->cmsg_level == SOL_SOCKET && c->cmsg_type == SCM_RIGHTS)
      for (int *f = (int *)CMSG_DATA(c); (char *)f < (char *)c + c->cmsg_len; ++f) close(*f);
  w->fin += k;
  return 0;
}

static int fixe(uint32_t v) { return (int32_t)v / 256; }

static void traiter(struct wl *w, uint32_t objet, uint16_t op, const uint32_t *a, int n) {
  (void)n;
  if (objet == 1) {  // wl_display
    if (op == 0) fprintf(stderr, "wayland : erreur %u sur l'objet %u : %s\n", a[1], a[0], (const char *)(a + 3));
    return;
  }
  if (objet == w->registre && op == 0) {  // global(nom, interface, version)
    const char *i = (const char *)(a + 2);
    uint32_t version = a[2 + (a[1] + 3) / 4];
    if (!strcmp(i, "wl_compositor")) w->compositeur = lier(w, a[0], i, version < 4 ? version : 4);
    else if (!strcmp(i, "wl_shm")) w->shm = lier(w, a[0], i, 1);
    else if (!strcmp(i, "xdg_wm_base")) w->wm = lier(w, a[0], i, 1);
    else if (!strcmp(i, "zxdg_decoration_manager_v1")) w->decorations = lier(w, a[0], i, 1);
    else if (!strcmp(i, "wl_seat") && !w->siege) {
      w->version_siege = version < 5 ? version : 5;
      w->siege = lier(w, a[0], i, w->version_siege);
    }
    return;
  }
  if (objet == w->synchro && op == 0) { w->synchro_ok = 1; return; }
  if (objet == w->wm && op == 0) {  // ping → pong
    msg_t m;
    debut(&m, w->wm, 3), u(&m, a[0]);
    envoyer(w, &m);
    return;
  }
  if (objet == w->siege && op == 0) {  // capabilities
    msg_t m;
    if ((a[0] & 1) && !w->pointeur) {
      w->pointeur = nouvel_objet(w);
      debut(&m, w->siege, 0), u(&m, w->pointeur);
      envoyer(w, &m);
    }
    if ((a[0] & 4) && !w->tactile) {
      w->tactile = nouvel_objet(w);
      debut(&m, w->siege, 2), u(&m, w->tactile);
      envoyer(w, &m);
    }
    return;
  }
  if (objet == w->xdg_surface && op == 0) {  // configure(serial)
    msg_t m;
    debut(&m, w->xdg_surface, 4), u(&m, a[0]);  // ack_configure
    envoyer(w, &m);
    w->configure = 1;
    if (w->l_attente > 0 && w->h_attente > 0 &&
        (w->l_attente != w->largeur || w->h_attente != w->hauteur)) {
      w->largeur = w->l_attente, w->hauteur = w->h_attente;
      pousser(w, (fenetre_ev_t){.type = FEN_TAILLE, .largeur = w->largeur, .hauteur = w->hauteur});
    } else {
      pousser(w, (fenetre_ev_t){.type = FEN_EXPOSITION});
    }
    return;
  }
  if (objet == w->toplevel) {
    if (op == 0) w->l_attente = (int32_t)a[0], w->h_attente = (int32_t)a[1];
    else if (op == 1) pousser(w, (fenetre_ev_t){.type = FEN_FERMETURE});
    return;
  }
  if (objet == w->pointeur) {
    switch (op) {
      case 0:  // enter(serial, surface, x, y)
        w->px = fixe(a[2]), w->py = fixe(a[3]);
        pousser(w, (fenetre_ev_t){.type = FEN_DEPLACEMENT, .x = w->px, .y = w->py});
        break;
      case 2:  // motion(temps, x, y)
        w->px = fixe(a[1]), w->py = fixe(a[2]);
        pousser(w, (fenetre_ev_t){.type = FEN_DEPLACEMENT, .x = w->px, .y = w->py});
        break;
      case 3: {  // button(serial, temps, bouton, état) ; codes evdev
        int b = a[2] == 0x110 ? 1 : a[2] == 0x112 ? 2 : a[2] == 0x111 ? 3 : 0;
        if (b) pousser(w, (fenetre_ev_t){.type = FEN_BOUTON, .bouton = b, .appui = a[3] == 1, .x = w->px, .y = w->py});
        break;
      }
      case 4:  // axis(temps, axe, valeur) : défilement vertical seulement
        if (a[1] == 0 && a[2]) {
          int b = (int32_t)a[2] < 0 ? 4 : 5;
          pousser(w, (fenetre_ev_t){.type = FEN_BOUTON, .bouton = b, .appui = 1, .x = w->px, .y = w->py});
          pousser(w, (fenetre_ev_t){.type = FEN_BOUTON, .bouton = b, .appui = 0, .x = w->px, .y = w->py});
        }
        break;
    }
    return;
  }
  if (objet == w->tactile) {  // un seul doigt, présenté comme le bouton gauche
    switch (op) {
      case 0:  // down(serial, temps, surface, id, x, y)
        if (w->doigt >= 0) break;
        w->doigt = (int32_t)a[3], w->px = fixe(a[4]), w->py = fixe(a[5]);
        pousser(w, (fenetre_ev_t){.type = FEN_DEPLACEMENT, .x = w->px, .y = w->py});
        pousser(w, (fenetre_ev_t){.type = FEN_BOUTON, .bouton = 1, .appui = 1, .x = w->px, .y = w->py});
        break;
      case 1:  // up(serial, temps, id)
        if ((int32_t)a[2] != w->doigt) break;
        w->doigt = -1;
        pousser(w, (fenetre_ev_t){.type = FEN_BOUTON, .bouton = 1, .appui = 0, .x = w->px, .y = w->py});
        break;
      case 2:  // motion(temps, id, x, y)
        if ((int32_t)a[1] != w->doigt) break;
        w->px = fixe(a[2]), w->py = fixe(a[3]);
        pousser(w, (fenetre_ev_t){.type = FEN_DEPLACEMENT, .x = w->px, .y = w->py});
        break;
      case 4:  // cancel
        if (w->doigt >= 0) pousser(w, (fenetre_ev_t){.type = FEN_BOUTON, .bouton = 1, .appui = 0, .x = w->px, .y = w->py});
        w->doigt = -1;
        break;
    }
    return;
  }
  for (int i = 0; i < NTAMPONS; ++i)
    if (objet == w->tampons[i].id && op == 0) w->tampons[i].occupe = 0;  // release
}

// Traite les messages complets du tampon de lecture.
static void depiler(struct wl *w) {
  while (w->fin - w->debut >= 8) {
    uint32_t *e = (uint32_t *)(w->lu + w->debut);
    uint32_t taille = e[1] >> 16;
    if (taille < 8 || w->fin - w->debut < (int)taille) break;
    traiter(w, e[0], e[1] & 0xFFFF, e + 2, (taille - 8) / 4);
    w->debut += taille;
  }
}

// Lit et traite jusqu'à ce que *drapeau devienne vrai.
static int attendre(struct wl *w, int *drapeau) {
  while (!*drapeau) {
    if (remplir(w)) return -1;
    depiler(w);
  }
  return 0;
}

/* --- Tampons --- */

static void liberer_tampon(struct wl *w, tampon_t *t) {
  if (!t->id) return;
  msg_t m;
  debut(&m, t->id, 0), envoyer(w, &m);    // wl_buffer.destroy
  debut(&m, t->pool, 1), envoyer(w, &m);  // wl_shm_pool.destroy
  munmap(t->pixels, t->octets);
  memset(t, 0, sizeof *t);
}

static int creer_tampon(struct wl *w, tampon_t *t, int l, int h) {
  t->octets = (size_t)l * h * 4;
  // Fichier anonyme partagé avec le compositeur : créé puis aussitôt
  // supprimé (memfd_create n'est pas exposé par cosmopolitan).
  const char *dossier = getenv("XDG_RUNTIME_DIR");
  char chemin[512];
  snprintf(chemin, sizeof chemin, "%s/organum-XXXXXX", dossier ? dossier : "/tmp");
  int fd = mkstemp(chemin);
  if (fd < 0) return -1;
  unlink(chemin);
  if (ftruncate(fd, t->octets)) { close(fd); return -1; }
  t->pixels = mmap(NULL, t->octets, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  if (t->pixels == MAP_FAILED) { close(fd); return -1; }
  msg_t m;
  t->pool = nouvel_objet(w);
  debut(&m, w->shm, 0), u(&m, t->pool), u(&m, t->octets);  // create_pool(id, fd, taille)
  m.fd = fd;
  envoyer(w, &m);
  close(fd);
  t->id = nouvel_objet(w);
  debut(&m, t->pool, 0);  // create_buffer(id, décalage, l, h, pas, XRGB8888)
  u(&m, t->id), u(&m, 0), u(&m, l), u(&m, h), u(&m, l * 4), u(&m, 1);
  envoyer(w, &m);
  t->largeur = l, t->hauteur = h, t->occupe = 0;
  return 0;
}

/* --- Interface --- */

wl_t *wl_ouvrir(const char *titre, int largeur, int hauteur) {
  const char *affichage = getenv("WAYLAND_DISPLAY");
  const char *dossier = getenv("XDG_RUNTIME_DIR");
  if (!affichage || !*affichage) return NULL;
  struct sockaddr_un adr = {.sun_family = AF_UNIX};
  if (affichage[0] == '/') snprintf(adr.sun_path, sizeof adr.sun_path, "%s", affichage);
  else if (dossier) snprintf(adr.sun_path, sizeof adr.sun_path, "%s/%s", dossier, affichage);
  else return NULL;
  int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd < 0) return NULL;
  if (connect(fd, (struct sockaddr *)&adr, sizeof adr)) { close(fd); return NULL; }

  struct wl *w = calloc(1, sizeof *w);
  w->fd = fd, w->suivant = 2, w->doigt = -1;
  w->largeur = largeur, w->hauteur = hauteur;

  msg_t m;
  w->registre = nouvel_objet(w);
  debut(&m, 1, 1), u(&m, w->registre);  // wl_display.get_registry
  envoyer(w, &m);
  // Deux allers-retours : les globaux, puis les événements des objets liés.
  synchroniser(w);
  if (attendre(w, &w->synchro_ok)) goto echec;
  synchroniser(w);
  if (attendre(w, &w->synchro_ok)) goto echec;
  if (!w->compositeur || !w->shm || !w->wm) {
    fprintf(stderr, "wayland : compositeur sans wl_shm ou xdg_wm_base\n");
    goto echec;
  }

  w->surface = nouvel_objet(w);
  debut(&m, w->compositeur, 0), u(&m, w->surface), envoyer(w, &m);
  w->xdg_surface = nouvel_objet(w);
  debut(&m, w->wm, 2), u(&m, w->xdg_surface), u(&m, w->surface), envoyer(w, &m);
  w->toplevel = nouvel_objet(w);
  debut(&m, w->xdg_surface, 1), u(&m, w->toplevel), envoyer(w, &m);
  debut(&m, w->toplevel, 2), chaine(&m, titre), envoyer(w, &m);
  debut(&m, w->toplevel, 3), chaine(&m, "organum"), envoyer(w, &m);
  if (w->decorations) {
    uint32_t d = nouvel_objet(w);
    debut(&m, w->decorations, 1), u(&m, d), u(&m, w->toplevel), envoyer(w, &m);
    debut(&m, d, 1), u(&m, 2), envoyer(w, &m);  // set_mode(server_side)
  }
  debut(&m, w->surface, 6), envoyer(w, &m);  // commit sans tampon
  if (attendre(w, &w->configure)) goto echec;
  return w;

echec:
  close(fd);
  free(w);
  return NULL;
}

int wl_fd(wl_t *w) { return w->fd; }

int wl_evenement(wl_t *w, fenetre_ev_t *ev, int attente_ms) {
  for (;;) {
    if (w->ftete != w->fqueue) {
      *ev = w->file[w->ftete++ % 64];
      return 1;
    }
    if (w->ferme) return 0;
    struct pollfd p = {.fd = w->fd, .events = POLLIN};
    if (poll(&p, 1, attente_ms) <= 0) return 0;
    if (remplir(w)) {
      w->ferme = 1;
      *ev = (fenetre_ev_t){.type = FEN_FERMETURE};
      return 1;
    }
    depiler(w);
    attente_ms = 0;
  }
}

void wl_afficher(wl_t *w, const uint32_t *pixels, int largeur, int hauteur) {
  tampon_t *t = NULL;
  for (int i = 0; i < NTAMPONS && !t; ++i)
    if (!w->tampons[i].occupe) t = &w->tampons[i];
  if (!t) return;  // les deux tampons sont chez le compositeur : image sautée
  if (t->largeur != largeur || t->hauteur != hauteur) {
    liberer_tampon(w, t);
    if (creer_tampon(w, t, largeur, hauteur)) return;
  }
  memcpy(t->pixels, pixels, t->octets);
  t->occupe = 1;
  msg_t m;
  debut(&m, w->surface, 1), u(&m, t->id), u(&m, 0), u(&m, 0), envoyer(w, &m);  // attach
  debut(&m, w->surface, 2), u(&m, 0), u(&m, 0), u(&m, largeur), u(&m, hauteur), envoyer(w, &m);  // damage
  debut(&m, w->surface, 6), envoyer(w, &m);  // commit
}

void wl_fermer(wl_t *w) {
  if (!w) return;
  for (int i = 0; i < NTAMPONS; ++i)
    if (w->tampons[i].pixels) munmap(w->tampons[i].pixels, w->tampons[i].octets);
  close(w->fd);
  free(w);
}
