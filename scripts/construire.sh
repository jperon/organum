#!/usr/bin/env bash
# Construit organum.com de bout en bout : dépendances, moteur, exécutable
# (dans l'arbre cosmopolitan), puis interface web. Résultat : web/build/organum.com
# Variables : JOBS (parallélisme, défaut nproc).
set -euo pipefail

RACINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JOBS="${JOBS:-$(nproc)}"

"$RACINE/scripts/dependances.sh"

echo "== programmes d'aide de cosmo_dlopen"
"$RACINE/cosmo/aide/construire.sh"

echo "== moteur"
make -C "$RACINE/moteur" -j"$JOBS"

echo "== organum (redbean + moteur)"
make -C "$RACINE/externe/cosmopolitan" -j"$JOBS" m= o//tool/organum/organum

echo "== interface web"
ORGANUM="$RACINE/externe/cosmopolitan/o//tool/organum/organum" "$RACINE/web/scripts/build.sh"
