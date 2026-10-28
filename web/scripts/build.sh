#!/usr/bin/env bash
# Compile les sources MoonScript et fabrique build/organum.com : l'exécutable
# organum (redbean + moteur, construit dans l'arbre cosmopolitan) plus le zip
# de l'interface web.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"
STAGE="$BUILD/stage"
ORGANUM="${ORGANUM:-$ROOT/../externe/cosmopolitan/o//tool/organum/organum}"
OUT="$BUILD/organum.com"

if [ ! -s "$ORGANUM" ]; then
  echo "ERREUR : $ORGANUM absent (voir scripts/construire.sh)." >&2
  exit 1
fi

rm -rf "$STAGE"
mkdir -p "$STAGE/.lua"

moonc -o "$STAGE/.init.lua" "$ROOT/src/init.moon"
for f in "$ROOT"/src/.lua/*.moon "$ROOT"/src/*.moon; do
  base="$(basename "$f" .moon)"
  [ "$base" = "init" ] && continue
  moonc -o "$STAGE/.lua/$base.lua" "$f"
done

# Nouveau fichier puis renommage : un organum en cours d'exécution garde
# l'ancien (écrire par-dessus modifierait son code en mémoire).
# Programme d'aide de cosmo_dlopen, précompilé (voir cosmo/aide) : organum
# n'a ainsi pas besoin de compilateur sur la machine cible.
AIDE="$ROOT/../cosmo/aide"
[ -x "$AIDE/dlopen-helper-glibc-x86_64" ] || "$AIDE/construire.sh"
mkdir -p "$STAGE/.cosmo"
cp "$AIDE"/dlopen-helper-*-x86_64 "$AIDE/dlopen-helper.c" "$STAGE/.cosmo/"
# Police de l'interface native (voir fenetre.moon), avec sa licence.
mkdir -p "$STAGE/.polices"
cp "$ROOT/../ui/polices/"* "$STAGE/.polices/"

cp "$ORGANUM" "$OUT.tmp"
(cd "$STAGE" && zip -q ../organum.com.tmp .init.lua .lua/*.lua .cosmo/* .polices/*)
chmod +x "$OUT.tmp"
mv -f "$OUT.tmp" "$OUT"

echo "archive : $OUT ($(du -h "$OUT" | cut -f1))"
