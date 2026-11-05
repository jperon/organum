#!/usr/bin/env bash
# Suite de tests unitaires rapide : aucune carte son, aucun affichage, aucun
# réseau, aucun démarrage du moteur, aucun sleep. Compile les modules
# MoonScript, les teste avec redbean en mode interpréteur (Lua 5.4), vérifie
# le JavaScript avec node --check, et éprouve les règles C/C++ pures.
#
#   scripts/tests-unitaires.sh
#
# Code 0 si tout passe. Durée visée : moins de 15 s après la première
# compilation (les objets C++ sont mis en cache dans web/build/objets-tests).
set -u

RACINE="$(cd "$(dirname "$0")/.." && pwd)"
DEBUT_NS=$(date +%s%N)
TMP="$(mktemp -d)" || exit 2
LUA="$TMP/lua"
JS="$TMP/js"
OBJDIR="$RACINE/web/build/objets-tests"
mkdir -p "$LUA" "$JS" "$OBJDIR"
TESTS=0
ECHECS=0
IGNORES=0

nettoyer() { rm -rf "$TMP"; }
trap nettoyer EXIT

ok() {
  TESTS=$((TESTS + 1))
  echo "OK    : $1"
}

echec() {
  TESTS=$((TESTS + 1))
  ECHECS=$((ECHECS + 1))
  echo "ÉCHEC : $1"
}

ignore() {
  IGNORES=$((IGNORES + 1))
  echo "IGNORÉ : $1"
}

# Deux outils sont indispensables ; node n'est requis que pour la syntaxe JS.
if ! command -v moonc >/dev/null 2>&1; then
  echo "ÉCHEC : moonc absent (MoonScript requis)" >&2
  exit 2
fi
if ! command -v redbean >/dev/null 2>&1; then
  echo "ÉCHEC : redbean absent (interpréteur Lua 5.4 requis)" >&2
  exit 2
fi

# Aucun moteur n'est lancé, mais on reste cohérent avec test-qualite.sh :
# jamais de temps réel susceptible d'affamer les interruptions.
ulimit -r 0 2>/dev/null || true
export -n WAYLAND_DISPLAY DISPLAY 2>/dev/null || true
unset WAYLAND_DISPLAY DISPLAY

# --- Compilation de tous les .moon -----------------------------------------
# Même découpage que web/scripts/build.sh : init -> .init.lua, les autres
# modules par leur nom de base, y compris .lua/html.moon.
while IFS= read -r f; do
  base="$(basename "$f" .moon)"
  if [ "$base" = "init" ] && [ "$(dirname "$f")" = "$RACINE/web/src" ]; then
    sortie="$LUA/.init.lua"
  elif [ "$(dirname "$f")" = "$RACINE/ui" ]; then
    mkdir -p "$TMP/ui"
    sortie="$TMP/ui/$base.lua"
  else
    sortie="$LUA/$base.lua"
  fi
  if message=$(moonc -o "$sortie" "$f" 2>&1); then
    ok "compilation : ${f#"$RACINE/"}"
  else
    echec "compilation : ${f#"$RACINE/"} ($message)"
  fi
done < <(find "$RACINE/web/src" "$RACINE/ui" -name '*.moon' -not -path '*/externe/*' | sort)

# --- Lint des globales -------------------------------------------------------
# Liste explicite des globales fournies par redbean ou le journal. Toute
# nouvelle globale (le bug de a498232 était une variable de branche devenue
# globale à la lecture) fait échouer la suite.
GLOBALES_PERMISES=" Slurp utf8 Log kLogWarn kLogInfo kLogFatal DecodeJson EncodeJson Barf SetStatus SetHeader Write GetBody GetMethod GetPath GetParam ProgramHeartbeatInterval GetHostOs unix arg nk organum Route "
while IFS= read -r f; do
  sortie=$(moonc -l --lint-stage global_access "$f" 2>&1 || true)
  globales=$(printf '%s\n' "$sortie" |
    sed -n 's/.*accessing global `\([^`]*\)`.*/\1/p' | sort -u)
  nouvelles=""
  for g in $globales; do
    case "$GLOBALES_PERMISES" in
      *" $g "*) ;;
      *) nouvelles="$nouvelles $g" ;;
    esac
  done
  if [ -n "$nouvelles" ]; then
    echec "globales non déclarées dans ${f#"$RACINE/"}:$nouvelles"
  else
    ok "lint des globales : ${f#"$RACINE/"}"
  fi
done < <(find "$RACINE/web/src" "$RACINE/ui" -name '*.moon' -not -path '*/externe/*' | sort)

# --- Tests Lua (redbean en mode interpréteur) --------------------------------
UNIT_LUA_PATH="$LUA/?.lua;$RACINE/web/tests/?.lua"
export UNIT_LUA_PATH
for test in "$RACINE"/web/tests/*.lua; do
  base="$(basename "$test")"
  case "$base" in
    aide.lua|js_extraire.lua) continue ;;
  esac
  sortie=$(env -u WAYLAND_DISPLAY -u DISPLAY redbean -i "$test" 2>&1)
  code=$?
  printf '%s\n' "$sortie"
  n_ok=$(printf '%s\n' "$sortie" | grep -c '^OK    :')
  n_echec=$(printf '%s\n' "$sortie" | grep -c '^ÉCHEC :')
  TESTS=$((TESTS + n_ok + n_echec))
  ECHECS=$((ECHECS + n_echec))
  if [ "$code" -ne 0 ] && [ "$n_echec" -eq 0 ]; then
    echec "$base : sortie en erreur (code $code)"
  fi
done

# --- Règle C du niveau de charge --------------------------------------------
if command -v gcc >/dev/null 2>&1; then
  if gcc -O2 -I "$RACINE/cosmo" "$RACINE/cosmo/tests/charge_niveau.c" \
       -o "$TMP/charge_niveau" 2>"$TMP/gcc.log"; then
    if "$TMP/charge_niveau" >"$TMP/charge.log" 2>&1; then
      ok "C : règle charge_niveau (table de vérité)"
    else
      cat "$TMP/charge.log"
      echec "C : règle charge_niveau"
    fi
  else
    cat "$TMP/gcc.log" >&2
    echec "C : compilation charge_niveau"
  fi
else
  ignore "C : gcc absent, règle charge_niveau non testée"
fi

# --- Tables C++ des tempéraments --------------------------------------------
# Compilation mise en cache : scale.cpp et le test ne changent pas entre deux
# exécutions. La première compilation (quelques secondes) est hors du budget
# de 15 s « une fois compilée ».
if command -v g++ >/dev/null 2>&1; then
  FLAGS=(-O2 -std=c++17 -DNDEBUG -I"$RACINE/moteur/compat" -I"$RACINE/moteur"
    -I"$RACINE/moteur/api" -I"$RACINE/moteur/o/binarydata"
    -I"$RACINE/externe/JUCE/modules"
    -DJUCE_GLOBAL_MODULE_SETTINGS_INCLUDED=1 -DJUCE_STANDALONE_APPLICATION=1
    -DJUCE_USE_CURL=0 -DJUCE_USE_FLAC=0 -DJUCE_USE_OGGVORBIS=0
    -DJUCE_USE_MP3AUDIOFORMAT=0 -DJUCE_USE_LAME_AUDIO_FORMAT=0
    -DJUCE_USE_WINDOWS_MEDIA_FORMAT=0 -ffunction-sections -fdata-sections)
  SCALE_CPP="$RACINE/moteur/aeolus/scale.cpp"
  TEST_CPP="$RACINE/moteur/tests/scale_tables.cpp"
  SCALE_O="$OBJDIR/scale.o"
  TEST_O="$OBJDIR/scale_tables.o"
  BIN="$OBJDIR/scale_tables"
  compile_cpp() {
    if [ ! -f "$SCALE_O" ] || [ "$SCALE_CPP" -nt "$SCALE_O" ]; then
      g++ "${FLAGS[@]}" -c "$SCALE_CPP" -o "$SCALE_O" 2>"$TMP/gpp.log" || return 1
    fi
    if [ ! -f "$TEST_O" ] || [ "$TEST_CPP" -nt "$TEST_O" ]; then
      g++ "${FLAGS[@]}" -c "$TEST_CPP" -o "$TEST_O" 2>>"$TMP/gpp.log" || return 1
    fi
    if [ ! -x "$BIN" ] || [ "$SCALE_O" -nt "$BIN" ] || [ "$TEST_O" -nt "$BIN" ]; then
      g++ "$SCALE_O" "$TEST_O" -Wl,--gc-sections -o "$BIN" 2>>"$TMP/gpp.log" || return 1
    fi
    return 0
  }
  if compile_cpp; then
    if "$BIN" >"$TMP/scale.log" 2>&1; then
      ok "C++ : tables des 11 tempéraments"
    else
      cat "$TMP/scale.log"
      echec "C++ : tables des 11 tempéraments"
    fi
  else
    cat "$TMP/gpp.log" >&2
    echec "C++ : compilation scale_tables"
  fi
else
  ignore "C++ : g++ absent, tables des tempéraments non testées"
fi

# --- Noms internes de Scale::getNameForType (données de scale.cpp) ----------
# Test de données : les onze libellés du moteur, dans l'ordre de l'enum.
SCALE_SRC="$RACINE/moteur/aeolus/scale.cpp" \
UNIT_LUA_PATH="$UNIT_LUA_PATH" \
redbean -i "$RACINE/web/tests/moteur_scale.lua" >"$TMP/noms.log" 2>&1
code=$?
cat "$TMP/noms.log"
n_ok=$(grep -c '^OK    :' "$TMP/noms.log")
n_echec=$(grep -c '^ÉCHEC :' "$TMP/noms.log")
TESTS=$((TESTS + n_ok + n_echec))
ECHECS=$((ECHECS + n_echec))
if [ "$code" -ne 0 ] && [ "$n_echec" -eq 0 ]; then
  echec "noms de Scale::getNameForType : sortie en erreur"
fi

# --- Syntaxe JavaScript ------------------------------------------------------
# Extracteur : écrit les scripts des pages compilées dans $TMP/js.
if command -v node >/dev/null 2>&1; then
  if JS_DIR="$JS" UNIT_LUA_PATH="$UNIT_LUA_PATH" \
     redbean -i "$RACINE/web/tests/js_extraire.lua" >"$TMP/js.log" 2>&1; then
    for f in "$JS"/*.js; do
      if node --check "$f" >"$TMP/node.log" 2>&1; then
        ok "JavaScript : syntaxe $(basename "$f")"
      else
        cat "$TMP/node.log"
        echec "JavaScript : syntaxe $(basename "$f")"
      fi
    done
  else
    cat "$TMP/js.log"
    echec "JavaScript : extraction des scripts"
  fi
else
  ignore "JavaScript : node absent, syntaxe non vérifiée"
fi

FIN_NS=$(date +%s%N)
DUREE_MS=$(( (FIN_NS - DEBUT_NS) / 1000000 ))
echo
echo "== $TESTS test(s), $ECHECS échec(s), $IGNORES ignoré(s), ${DUREE_MS} ms"
[ "$ECHECS" -eq 0 ]
