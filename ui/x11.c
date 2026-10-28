/* Client X11 minimal : connexion, authentification MIT-MAGIC-COOKIE-1,
 * une fenêtre, PutImage et lecture des événements. Références : « X Window
 * System Protocol », X Consortium Standard, X11R7. Ordre des octets du
 * client : petit-boutiste ('l'). */
#include "protocoles.h"

#include <errno.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <cosmo.h>

struct x11 {
  int fd;
  uint32_t base, masque, suivant;  // allocation des identifiants
  uint32_t racine, visuel, fenetre, gc;
  uint8_t profondeur;
  uint32_t max_requete;            // en octets
  uint32_t atome_protocoles, atome_fermer;
  int largeur, hauteur;
  // Tampon de lecture
  uint8_t tampon[4096];
  int debut, fin;
};

static int ecrire_tout(int fd, const void *p, size_t n) {
  const uint8_t *o = p;
  while (n) {
    ssize_t k = write(fd, o, n);
    if (k < 0) {
      if (errno == EINTR) continue;
      return -1;
    }
    o += k, n -= k;
  }
  return 0;
}

// Lit exactement n octets (bloquant), en passant par le tampon.
static int lire_tout(x11_t *x, void *p, size_t n) {
  uint8_t *o = p;
  while (n) {
    if (x->debut == x->fin) {
      ssize_t k = read(x->fd, x->tampon, sizeof x->tampon);
      if (k < 0 && errno == EINTR) continue;
      if (k <= 0) return -1;
      x->debut = 0, x->fin = k;
    }
    size_t m = x->fin - x->debut;
    if (m > n) m = n;
    memcpy(o, x->tampon + x->debut, m);
    x->debut += m, o += m, n -= m;
  }
  return 0;
}

static uint16_t lu16(const uint8_t *p) { return p[0] | p[1] << 8; }
static uint32_t lu32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }
static uint16_t be16(const uint8_t *p) { return p[0] << 8 | p[1]; }
static int pad4(int n) { return (4 - (n & 3)) & 3; }

// Construction des requêtes
typedef struct { uint8_t o[256]; int n; } req_t;
static void r8(req_t *r, uint8_t v) { r->o[r->n++] = v; }
static void r16(req_t *r, uint16_t v) { r8(r, v), r8(r, v >> 8); }
static void r32(req_t *r, uint32_t v) { r16(r, v), r16(r, v >> 16); }
static void rdonnees(req_t *r, const void *p, int n) {
  memcpy(r->o + r->n, p, n), r->n += n;
  while (r->n & 3) r8(r, 0);
}
static void rlongueur(req_t *r) { r->o[2] = (r->n / 4) & 0xFF, r->o[3] = (r->n / 4) >> 8; }

// Cookie MIT-MAGIC-COOKIE-1 du fichier Xauthority pour l'affichage donné.
static int lire_cookie(const char *numero, uint8_t *cookie, int *ncookie) {
  char chemin[512];
  const char *f = getenv("XAUTHORITY");
  if (!f || !*f) {
    const char *home = getenv("HOME");
    if (!home) return -1;
    snprintf(chemin, sizeof chemin, "%s/.Xauthority", home);
    f = chemin;
  }
  FILE *fp = fopen(f, "rb");
  if (!fp) return -1;
  char hote[256] = "";
  gethostname(hote, sizeof hote - 1);
  int trouve = -1;
  for (;;) {
    uint8_t b[2];
    if (fread(b, 1, 2, fp) != 2) break;
    uint16_t famille = be16(b);
    char champs[4][256];
    int longueurs[4], ok = 1;
    for (int i = 0; i < 4 && ok; ++i) {
      if (fread(b, 1, 2, fp) != 2) { ok = 0; break; }
      int n = be16(b);
      if (n > 255 || fread(champs[i], 1, n, fp) != (size_t)n) { ok = 0; break; }
      champs[i][n] = 0, longueurs[i] = n;
    }
    if (!ok) break;
    // champs : adresse, numéro d'affichage, nom du protocole, données
    // Local, Wild, ou Internet (IPv4/IPv6 : connexions TCP)
    int utilisable = famille == 256 || famille == 0xFFFF || famille == 0 || famille == 6;
    if (!utilisable || strcmp(champs[2], "MIT-MAGIC-COOKIE-1") || longueurs[3] > 16) continue;
    if (longueurs[1] && strcmp(champs[1], numero)) continue;
    if (famille == 256 && strcmp(champs[0], hote) && trouve >= 0) continue;
    memcpy(cookie, champs[3], longueurs[3]);
    *ncookie = trouve = longueurs[3];
    if (famille == 256 && !strcmp(champs[0], hote)) break;
  }
  fclose(fp);
  return trouve >= 0 ? 0 : -1;
}

static uint32_t nouvel_id(x11_t *x) { return x->base | (x->suivant++ & x->masque); }

// Attend la réponse à la dernière requête (les événements reçus d'ici là
// sont ignorés : on ne l'utilise qu'avant l'affichage de la fenêtre).
static int attendre_reponse(x11_t *x, uint8_t rep[32]) {
  for (;;) {
    if (lire_tout(x, rep, 32)) return -1;
    if (rep[0] == 1) {
      uint32_t reste = lu32(rep + 4) * 4;
      uint8_t poubelle[256];
      while (reste) {
        uint32_t m = reste > sizeof poubelle ? sizeof poubelle : reste;
        if (lire_tout(x, poubelle, m)) return -1;
        reste -= m;
      }
      return 0;
    }
    if (rep[0] == 0) return -1;  // erreur
  }
}

static uint32_t interner(x11_t *x, const char *nom) {
  req_t r = {.n = 0};
  r8(&r, 16), r8(&r, 0), r16(&r, 0);  // InternAtom, only-if-exists = faux
  r16(&r, strlen(nom)), r16(&r, 0);
  rdonnees(&r, nom, strlen(nom));
  rlongueur(&r);
  uint8_t rep[32];
  if (ecrire_tout(x->fd, r.o, r.n) || attendre_reponse(x, rep)) return 0;
  return lu32(rep + 8);
}

static void propriete(x11_t *x, uint32_t prop, uint32_t type, int format, const void *d, int n) {
  req_t r = {.n = 0};
  r8(&r, 18), r8(&r, 0), r16(&r, 0);  // ChangeProperty, Replace
  r32(&r, x->fenetre), r32(&r, prop), r32(&r, type);
  r8(&r, format), r8(&r, 0), r16(&r, 0);
  r32(&r, n);
  rdonnees(&r, d, n * format / 8);
  rlongueur(&r);
  ecrire_tout(x->fd, r.o, r.n);
}

// Connexion au serveur : socket Unix pour « :n » (ou « unix:n »), TCP vers
// le port 6000 + n pour « hôte:n » — cas des serveurs X pour Windows
// (VcXsrv, Xming…), qui n'écoutent qu'en TCP.
static int connecter(const char *hote, int n) {
  if (!*hote || !strcmp(hote, "unix")) {
    struct sockaddr_un adr = {.sun_family = AF_UNIX};
    snprintf(adr.sun_path, sizeof adr.sun_path, "/tmp/.X11-unix/X%d", n);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd >= 0 && connect(fd, (struct sockaddr *)&adr, sizeof adr) == 0) return fd;
    if (fd >= 0) close(fd);
    if (*hote) return -1;
    hote = "localhost";  // « :n » sans socket Unix (Windows) : essai en TCP
  }
  char port[16];
  snprintf(port, sizeof port, "%d", 6000 + n);
  struct addrinfo indice = {.ai_family = AF_UNSPEC, .ai_socktype = SOCK_STREAM}, *res;
  if (getaddrinfo(hote, port, &indice, &res)) return -1;
  int fd = -1;
  for (struct addrinfo *a = res; a; a = a->ai_next) {
    fd = socket(a->ai_family, a->ai_socktype, a->ai_protocol);
    if (fd < 0) continue;
    if (connect(fd, a->ai_addr, a->ai_addrlen) == 0) break;
    close(fd), fd = -1;
  }
  freeaddrinfo(res);
  if (fd >= 0) setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &(int){1}, sizeof(int));
  return fd;
}

x11_t *x11_ouvrir(const char *titre, int largeur, int hauteur) {
  const char *d = getenv("DISPLAY");
  // Sous Windows, DISPLAY est rarement définie : serveur local par défaut.
  if ((!d || !*d) && IsWindows()) d = "localhost:0";
  const char *deux_points = d ? strrchr(d, ':') : NULL;
  if (!deux_points) return NULL;
  char hote[256];
  snprintf(hote, sizeof hote, "%.*s", (int)(deux_points - d), d);
  int n = atoi(deux_points + 1);  // « :0.0 » : l'écran après le point est ignoré
  char numero[16];
  snprintf(numero, sizeof numero, "%d", n);

  int fd = connecter(hote, n);
  if (fd < 0) return NULL;
  x11_t *x = calloc(1, sizeof *x);
  x->fd = fd;

  // Établissement de la connexion
  uint8_t cookie[16];
  int ncookie = 0;
  int auth = lire_cookie(numero, cookie, &ncookie) == 0;
  const char *nom = auth ? "MIT-MAGIC-COOKIE-1" : "";
  req_t r = {.n = 0};
  r8(&r, 'l'), r8(&r, 0), r16(&r, 11), r16(&r, 0);
  r16(&r, strlen(nom)), r16(&r, auth ? ncookie : 0), r16(&r, 0);
  rdonnees(&r, nom, strlen(nom));
  if (auth) rdonnees(&r, cookie, ncookie);
  uint8_t ent[8];
  if (ecrire_tout(fd, r.o, r.n) || lire_tout(x, ent, 8)) goto echec;
  uint32_t taille = lu16(ent + 6) * 4;
  uint8_t *s = malloc(taille);
  if (lire_tout(x, s, taille)) { free(s); goto echec; }
  if (ent[0] != 1) {
    fprintf(stderr, "x11 : connexion refusée : %.*s\n", ent[1], (char *)s);
    free(s);
    goto echec;
  }
  x->base = lu32(s + 4), x->masque = lu32(s + 8);
  uint16_t nvendeur = lu16(s + 16);
  x->max_requete = lu16(s + 18) * 4;
  uint8_t nformats = s[21];
  uint8_t *ecran = s + 32 + nvendeur + pad4(nvendeur) + 8 * nformats;
  x->racine = lu32(ecran);
  x->visuel = lu32(ecran + 32);
  x->profondeur = ecran[38];
  // Pas plus grande que l'écran (sans gestionnaire de fenêtres, personne ne
  // la ramènerait à sa taille).
  if (largeur > lu16(ecran + 20)) largeur = lu16(ecran + 20);
  if (hauteur > lu16(ecran + 22)) hauteur = lu16(ecran + 22);
  free(s);
  if (x->profondeur != 24) {
    fprintf(stderr, "x11 : profondeur %d non prise en charge\n", x->profondeur);
    goto echec;
  }

  // Fenêtre : fond noir, événements utiles.
  x->fenetre = nouvel_id(x);
  x->largeur = largeur, x->hauteur = hauteur;
  r.n = 0;
  r8(&r, 1), r8(&r, x->profondeur), r16(&r, 0);  // CreateWindow
  r32(&r, x->fenetre), r32(&r, x->racine);
  r16(&r, 0), r16(&r, 0), r16(&r, largeur), r16(&r, hauteur);
  r16(&r, 0), r16(&r, 1);  // bordure, InputOutput
  r32(&r, x->visuel);
  r32(&r, 0x2 | 0x800);    // CWBackPixel | CWEventMask
  r32(&r, 0);
  r32(&r, 0x1 | 0x2 | 0x4 | 0x8 | 0x40 | 0x8000 | 0x20000);
  // Key{Press,Release}, Button{Press,Release}, PointerMotion, Exposure, StructureNotify
  rlongueur(&r);
  ecrire_tout(fd, r.o, r.n);

  x->gc = nouvel_id(x);
  r.n = 0;
  r8(&r, 55), r8(&r, 0), r16(&r, 0);  // CreateGC
  r32(&r, x->gc), r32(&r, x->fenetre), r32(&r, 0);
  rlongueur(&r);
  ecrire_tout(fd, r.o, r.n);

  propriete(x, 39 /* WM_NAME */, 31 /* STRING */, 8, titre, strlen(titre));
  x->atome_protocoles = interner(x, "WM_PROTOCOLS");
  x->atome_fermer = interner(x, "WM_DELETE_WINDOW");
  if (x->atome_protocoles && x->atome_fermer)
    propriete(x, x->atome_protocoles, 4 /* ATOM */, 32, &x->atome_fermer, 1);

  r.n = 0;
  r8(&r, 8), r8(&r, 0), r16(&r, 2), r32(&r, x->fenetre);  // MapWindow
  ecrire_tout(fd, r.o, r.n);
  return x;

echec:
  close(fd);
  free(x);
  return NULL;
}

int x11_fd(x11_t *x) { return x->fd; }
void x11_taille(x11_t *x, int *l, int *h) { *l = x->largeur, *h = x->hauteur; }

int x11_evenement(x11_t *x, fenetre_ev_t *ev, int attente_ms) {
  for (;;) {
    if (x->debut == x->fin) {
      struct pollfd p = {.fd = x->fd, .events = POLLIN};
      int k = poll(&p, 1, attente_ms);
      if (k <= 0) return 0;
      if (p.revents & (POLLHUP | POLLERR)) {
        *ev = (fenetre_ev_t){.type = FEN_FERMETURE};
        return 1;
      }
    }
    uint8_t e[32];
    if (lire_tout(x, e, 32)) {
      *ev = (fenetre_ev_t){.type = FEN_FERMETURE};
      return 1;
    }
    memset(ev, 0, sizeof *ev);
    switch (e[0] & 0x7F) {
      case 0:  // erreur : signalée, puis ignorée
        fprintf(stderr, "x11 : erreur %d (requête %d)\n", e[1], e[10]);
        continue;
      case 1:  // réponse inattendue : on saute ses données
        for (uint32_t reste = lu32(e + 4) * 4; reste;) {
          uint8_t p[256];
          uint32_t m = reste > sizeof p ? sizeof p : reste;
          if (lire_tout(x, p, m)) break;
          reste -= m;
        }
        continue;
      case 2:
      case 3:
        ev->type = FEN_TOUCHE, ev->code = e[1], ev->appui = (e[0] & 0x7F) == 2;
        return 1;
      case 4:
      case 5:
        ev->type = FEN_BOUTON, ev->bouton = e[1], ev->appui = (e[0] & 0x7F) == 4;
        ev->x = (int16_t)lu16(e + 24), ev->y = (int16_t)lu16(e + 26);
        return 1;
      case 6:
        ev->type = FEN_DEPLACEMENT;
        ev->x = (int16_t)lu16(e + 24), ev->y = (int16_t)lu16(e + 26);
        return 1;
      case 12:
        if (lu16(e + 16)) continue;  // seulement la dernière exposition
        ev->type = FEN_EXPOSITION;
        return 1;
      case 22: {
        int l = lu16(e + 20), h = lu16(e + 22);
        if (l == x->largeur && h == x->hauteur) continue;
        x->largeur = l, x->hauteur = h;
        ev->type = FEN_TAILLE, ev->largeur = l, ev->hauteur = h;
        return 1;
      }
      case 33:
        if (lu32(e + 8) == x->atome_protocoles && lu32(e + 12) == x->atome_fermer) {
          ev->type = FEN_FERMETURE;
          return 1;
        }
        continue;
      default:
        continue;
    }
  }
}

void x11_afficher(x11_t *x, const uint32_t *pixels, int largeur, int hauteur) {
  // PutImage par bandes de lignes, dans la limite de taille des requêtes.
  int lignes = (x->max_requete - 24) / (largeur * 4);
  if (lignes < 1) return;
  for (int y = 0; y < hauteur; y += lignes) {
    int h = hauteur - y < lignes ? hauteur - y : lignes;
    uint32_t octets = (uint32_t)largeur * h * 4;
    req_t r = {.n = 0};
    r8(&r, 72), r8(&r, 2), r16(&r, (24 + octets) / 4);  // PutImage, ZPixmap
    r32(&r, x->fenetre), r32(&r, x->gc);
    r16(&r, largeur), r16(&r, h), r16(&r, 0), r16(&r, y);
    r8(&r, 0), r8(&r, x->profondeur), r16(&r, 0);
    if (ecrire_tout(x->fd, r.o, r.n) ||
        ecrire_tout(x->fd, pixels + (size_t)y * largeur, octets))
      return;
  }
}

void x11_fermer(x11_t *x) {
  if (!x) return;
  close(x->fd);
  free(x);
}
