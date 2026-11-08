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
# Un seul appel à moonc pour l'arborescence (web/src et ui), puis le module
# caché .lua/html.moon que moonc ne parcourt pas. Chaque fichier attendu est
# ensuite vérifié un par un, comme le fait web/scripts/build.sh.
mkdir -p "$TMP/moon" "$LUA"
if message=$( (cd "$RACINE" && moonc -t "$TMP/moon" web/src ui) 2>&1 ); then
  :
else
  printf '%s\n' "$message" >&2
fi
if message=$(moonc -o "$LUA/html.lua" "$RACINE/web/src/.lua/html.moon" 2>&1); then
  :
else
  printf '%s\n' "$message" >&2
fi
# Les modules visibles servent aux tests ; init est compilé comme les autres.
cp "$TMP/moon/src/"*.lua "$LUA/" 2>/dev/null || true
cp "$LUA/init.lua" "$LUA/.init.lua" 2>/dev/null || true
while IFS= read -r f; do
  base="$(basename "$f" .moon)"
  case "$f" in
    "$RACINE"/web/src/.lua/*) sortie="$LUA/$base.lua" ;;
    "$RACINE"/web/src/*) sortie="$TMP/moon/src/$base.lua" ;;
    "$RACINE"/ui/*) sortie="$TMP/moon/ui/$base.lua" ;;
    *) sortie="$TMP/moon/$base.lua" ;;
  esac
  if [ -f "$sortie" ]; then
    ok "compilation : ${f#"$RACINE/"}"
  else
    echec "compilation : ${f#"$RACINE/"} (sortie absente)"
  fi
done < <(find "$RACINE/web/src" "$RACINE/ui" -name '*.moon' -not -path '*/externe/*' | sort)

# --- Lint des globales -------------------------------------------------------
# Un seul passage de moonc sur les deux arborescences, puis lecture par
# fichier. Liste explicite des globales fournies par redbean ou le journal :
# toute nouvelle globale (le bug de a498232 était une variable de branche
# devenue globale à la lecture) fait échouer la suite.
GLOBALES_PERMISES=" Slurp utf8 Log kLogWarn kLogInfo kLogFatal DecodeJson EncodeJson Barf SetStatus SetHeader Write GetBody GetClientAddr GetCryptoHash GetHeader GetMethod GetParam GetPath GetRandomBytes GetUrl ProgramHeartbeatInterval ProgramAddr GetHostOs unix arg nk organum Route "
LINT_LOG="$TMP/lint.log"
(cd "$RACINE" && moonc -l --lint-stage global_access web/src ui) >"$LINT_LOG" 2>&1 || true
awk -v racine="$RACINE/" '
  /^[^[:space:]].*\.moon$/ { f = $0; sub("^" racine, "", f); next }
  /accessing global `[^`]*`/ {
    s = $0
    sub(/.*accessing global `/, "", s)
    sub(/`.*/, "", s)
    cle = f "|" s
    if (!(cle in vu)) { vu[cle] = 1; print f "\t" s }
  }
' "$LINT_LOG" >"$TMP/globales.tsv"
while IFS= read -r f; do
  rel="${f#"$RACINE/"}"
  globales=$(awk -F '\t' -v f="$rel" '$1 == f { printf " %s", $2 }' "$TMP/globales.tsv")
  nouvelles=""
  for g in $globales; do
    case "$GLOBALES_PERMISES" in
      *" $g "*) ;;
      *) nouvelles="$nouvelles $g" ;;
    esac
  done
  if [ -n "$nouvelles" ]; then
    echec "globales non déclarées dans $rel:$nouvelles"
  else
    ok "lint des globales : $rel"
  fi
done < <(find "$RACINE/web/src" "$RACINE/ui" -name '*.moon' -not -path '*/externe/*' | sort)

# --- Tests Lua (redbean en mode interpréteur) --------------------------------
UNIT_LUA_PATH="$LUA/?.lua;$RACINE/web/tests/?.lua"
export UNIT_LUA_PATH
for test in "$RACINE"/web/tests/*.lua; do
  base="$(basename "$test")"
  case "$base" in
    aide.lua|js_extraire.lua|moteur_scale.lua) continue ;;
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

# --- Règle C du cadencement de la sortie « null » ---------------------------
if command -v gcc >/dev/null 2>&1; then
  if gcc -O2 -I "$RACINE/cosmo" "$RACINE/cosmo/tests/sortie_null.c" \
       -o "$TMP/sortie_null" 2>"$TMP/gcc-sortie.log"; then
    if "$TMP/sortie_null" >"$TMP/sortie.log" 2>&1; then
      ok "C : règle sortie_null (null seul, défaut inactif)"
    else
      cat "$TMP/sortie.log"
      echec "C : règle sortie_null"
    fi
  else
    cat "$TMP/gcc-sortie.log" >&2
    echec "C : compilation sortie_null"
  fi
else
  ignore "C : gcc absent, règle sortie_null non testée"
fi

# --- Filtre de transposition MIDI -------------------------------------------
if command -v gcc >/dev/null 2>&1; then
  if gcc -O2 -I "$RACINE/cosmo" "$RACINE/cosmo/tests/transposition.c" \
       -o "$TMP/transposition" 2>"$TMP/gcc-transposition.log"; then
    if "$TMP/transposition" >"$TMP/transposition.log" 2>&1; then
      ok "C : filtre de transposition (décalage, tenue, canaux)"
    else
      cat "$TMP/transposition.log"
      echec "C : filtre de transposition"
    fi
  else
    cat "$TMP/gcc-transposition.log" >&2
    echec "C : compilation transposition"
  fi
else
  ignore "C : gcc absent, filtre de transposition non testé"
fi

# --- Codec du protocole MIDI macOS ------------------------------------------
if command -v gcc >/dev/null 2>&1; then
  if gcc -O2 -I "$RACINE/plateforme" "$RACINE/plateforme/tests/trames_midi.c" \
       -o "$TMP/trames_midi" 2>"$TMP/gcc-trames.log"; then
    if "$TMP/trames_midi" >"$TMP/trames.log" 2>&1; then
      ok "C : codec MIDI macOS (poignée, trames, DEVICE_LIST, chemin)"
    else
      cat "$TMP/trames.log"
      echec "C : codec MIDI macOS"
    fi
  else
    cat "$TMP/gcc-trames.log" >&2
    echec "C : compilation trames_midi"
  fi
else
  ignore "C : gcc absent, codec MIDI macOS non testé"
fi

# --- Tables C++ des tempéraments --------------------------------------------
# Compilation mise en cache : scale.cpp et le test ne changent pas entre deux
# exécutions. La première compilation (quelques secondes) est hors du budget
# de 15 s « une fois compilée ».
if [ ! -d "$RACINE/externe/JUCE/modules" ] || \
   [ ! -f "$RACINE/moteur/o/binarydata/BinaryData.h" ]; then
  # scale.cpp inclut aeolus/scale.h, qui tire globals.h -> JuceHeader.h ->
  # les modules JUCE et BinaryData : ces dépendances ne sont pas suivies par
  # git (dossier externe/ ignoré, moteur/o/ produit). Dans un worktree
  # propre, le banc ne peut pas être compilé sans elles ; on l'ignore avec
  # sa raison plutôt que d'échouer à tort.
  ignore "C++ : tables des 11 tempéraments (dépendances externes absentes : externe/JUCE, moteur/o/binarydata)"
elif command -v g++ >/dev/null 2>&1; then
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
