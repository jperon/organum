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
#include "tool/net/redbean.c"
