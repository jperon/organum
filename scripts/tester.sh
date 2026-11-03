#!/usr/bin/env bash
# Tests de la couche plate-forme, construits dans l'arbre cosmopolitan.
# À lancer après scripts/construire.sh (ou avec ORGANUM_TESTS=1).
# Variables : JOBS (parallélisme, défaut nproc), ORGANUM_TEST_LIBASOUND
# (chemin d'une vraie libasound pour le cas de succès).
set -euo pipefail

RACINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JOBS="${JOBS:-$(nproc)}"
COSMO="$RACINE/externe/cosmopolitan"

echo "== test diagnostic libasound"
make -C "$COSMO" -j"$JOBS" m= o//tool/organum/erreur_alsa

TEST="$COSMO/o//tool/organum/erreur_alsa"
LIBASOUND="${ORGANUM_TEST_LIBASOUND:-}"
if [ -z "$LIBASOUND" ] && command -v ldconfig >/dev/null 2>&1; then
	LIBASOUND="$(ldconfig -p 2>/dev/null | awk '/libasound\.so\.2 /{print $NF; exit}')" || true
fi

if [ -n "$LIBASOUND" ]; then
	"$TEST" "$LIBASOUND"
else
	"$TEST"
fi

echo "== test construction des chemins ALSA"
make -C "$COSMO" -j"$JOBS" m= o//tool/organum/chemins_alsa
"$COSMO/o//tool/organum/chemins_alsa"

echo "== test injection open/fcntl du chemin ioctl"
make -C "$COSMO" -j"$JOBS" m= o//tool/organum/injection_alsa
"$COSMO/o//tool/organum/injection_alsa"

echo "== test énumération et abonnements des ports MIDI"
make -C "$COSMO" -j"$JOBS" m= o//tool/organum/ports_midi
"$COSMO/o//tool/organum/ports_midi"
