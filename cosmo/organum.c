// organum : redbean, plus le module Lua « organum » (moteur d'Aeolus).
//
// redbean.c est repris tel quel : son appel à luaL_openlibs() est détourné
// pour charger aussi notre module, ce qui évite de modifier tool/net.
// ORGANUM_WEB (organum_web.c) : sans le module « nk » de l'interface native.
#include "third_party/lua/lauxlib.h"
#include "third_party/lua/lualib.h"

int luaopen_organum(lua_State *L);
#ifndef ORGANUM_WEB
int luaopen_nk(lua_State *L);
#endif

static void OrganumOpenLibs(lua_State *L) {
  luaL_openlibs(L);
  luaL_requiref(L, "organum", luaopen_organum, 1);
  lua_pop(L, 1);
#ifndef ORGANUM_WEB
  luaL_requiref(L, "nk", luaopen_nk, 1);
  lua_pop(L, 1);
#endif
}

#define luaL_openlibs OrganumOpenLibs
// Le main de redbean est renommé pour qu'organum puisse insérer « -X »
// avant de le lui passer (voir OrganumMain plus bas).
#define main redbean_main
#include "tool/net/redbean.c"
#undef main

// Vrai si la ligne de commande demande un certificat TLS. On parcourt les
// options courtes comme getopt, en sautant l'argument des options qui en
// attendent un (la table GETOPTS de redbean), pour ne pas confondre un
// chemin contenant « C » ou « K » avec -C/-K.
static bool OrganumCertificatDemande(int argc, char *argv[]) {
  for (int i = 1; i < argc; ++i) {
    const char *a = argv[i];
    if (!strcmp(a, "--"))
      break;
    if (a[0] != '-' || !a[1] || a[1] == '-')
      continue;
    for (const char *p = a + 1; *p; ++p) {
      const char *d = strchr(GETOPTS, *p);
      if (!d)
        break;
      if (*p == 'C' || *p == 'K')
        return true;
      if (d[1] == ':') {
        if (!p[1])
          ++i;  // argument dans l'élément suivant
        break;
      }
    }
  }
  return false;
}

// redbean génère un certificat TLS auto-signé entre Listen() et EventLoop(),
// et ConfigureCertificate reverse-résout chaque adresse non-loopback. Sous
// XNU, getnameinfo(..., NI_NAMEREQD) sur 0.0.0.0 échoue en ~17 s, deux fois
// (EC puis RSA) : le port écoute alors ~34 s sans que personne n'appelle
// accept(). organum ne sert qu'en HTTP et ne configure jamais TLS ; on passe
// donc « -X » (unsecure), sauf si l'utilisateur fournit -C/-K.
int main(int argc, char *argv[]) {
  if (OrganumCertificatDemande(argc, argv))
    return redbean_main(argc, argv);
  char **argv2 = malloc((argc + 2) * sizeof(*argv2));
  if (!argv2)
    return redbean_main(argc, argv);
  argv2[0] = argv[0];
  argv2[1] = "-X";
  for (int i = 1; i <= argc; ++i)
    argv2[i + 1] = argv[i];  // recopie aussi le NULL final
  return redbean_main(argc + 1, argv2);
}
