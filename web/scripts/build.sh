#!/usr/bin/env bash
# Compile les sources MoonScript et fabrique build/organum.com : l'exécutable
# organum (redbean + moteur, construit dans l'arbre cosmopolitan) plus le zip
# de l'interface web.
#
# ORGANUM_WEB=1 : variante sans interface native, build/organum-web.com, à
# partir de l'exécutable organum-web (o//tool/organum/organum-web).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"
WEB="${ORGANUM_WEB:-}"
NOM="organum${WEB:+-web}"
ORGANUM="${ORGANUM:-$ROOT/../externe/cosmopolitan/o//tool/organum/$NOM}"
OUT="$BUILD/$NOM.com"
STAGE="$BUILD/stage-$NOM"

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
  [ -n "$WEB" ] && [ "$base" = "fenetre" ] && continue
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
FICHIERS=".init.lua .lua/*.lua .cosmo/*"
if [ -z "$WEB" ]; then
  mkdir -p "$STAGE/.polices"
  cp "$ROOT/../ui/polices/"* "$STAGE/.polices/"
  FICHIERS+=" .polices/*"
fi

cp "$ORGANUM" "$OUT.tmp"
(cd "$STAGE" && zip -q "$OUT.tmp" $FICHIERS)
chmod +x "$OUT.tmp"
mv -f "$OUT.tmp" "$OUT"

echo "archive : $OUT ($(du -h "$OUT" | cut -f1))"
