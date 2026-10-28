// organum : redbean, plus le module Lua « organum » (moteur d'Aeolus).
//
// redbean.c est repris tel quel : son appel à luaL_openlibs() est détourné
// pour charger aussi notre module, ce qui évite de modifier tool/net.
#include "third_party/lua/lauxlib.h"
#include "third_party/lua/lualib.h"

int luaopen_organum(lua_State *L);
int luaopen_nk(lua_State *L);

static void OrganumOpenLibs(lua_State *L) {
  luaL_openlibs(L);
  luaL_requiref(L, "organum", luaopen_organum, 1);
  lua_pop(L, 1);
  luaL_requiref(L, "nk", luaopen_nk, 1);
  lua_pop(L, 1);
}

#define luaL_openlibs OrganumOpenLibs
#include "tool/net/redbean.c"
