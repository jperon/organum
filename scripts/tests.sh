#!/bin/sh
# Suite complète d'organum : unitaires, longs, bout en bout. S'arrête au
# premier échec et nomme la suite en cause.
#
#   scripts/tests.sh            # les trois suites
#   scripts/tests.sh --rapide   # unitaires seulement (suite rapide)
#
# Code non nul dès qu'une suite échoue ; les suites suivantes ne sont alors
# pas lancées.
set -u

# Sûreté : mêmes précautions que chaque suite (temps réel, affichage).
ulimit -r 0 2>/dev/null || {
  echo "ÉCHEC : ulimit -r 0 impossible ; ne pas lancer le moteur sans temps réel" >&2
  exit 2
}
unset WAYLAND_DISPLAY DISPLAY

RACINE="$(cd "$(dirname "$0")/.." && pwd)"
RAPIDE=0
if [ "${1:-}" = "--rapide" ]; then
  RAPIDE=1
elif [ $# -gt 0 ]; then
  echo "usage : $0 [--rapide]" >&2
  exit 2
fi

duree() {
  printf '%s.%03d s' "$(( ($2 - $1) / 1000000000 ))" "$(( (($2 - $1) / 1000000) % 1000 ))"
}

lancer() {
  nom=$1
  script=$2
  echo
  echo "===== $nom ====="
  debut=$(date +%s%N)
  if sh "$RACINE/$script"; then
    fin=$(date +%s%N)
    echo "===== $nom : OK ($(duree "$debut" "$fin"))"
    return 0
  fi
  fin=$(date +%s%N)
  echo "===== $nom : ÉCHEC ($(duree "$debut" "$fin"))" >&2
  return 1
}

if ! lancer "tests unitaires" "scripts/tests-unitaires.sh"; then
  echo "Suite en cause : tests unitaires" >&2
  exit 1
fi

if [ "$RAPIDE" -eq 1 ]; then
  echo
  echo "== suite rapide : tests unitaires seulement"
  exit 0
fi

if ! lancer "tests longs" "scripts/tests-longs.sh"; then
  echo "Suite en cause : tests longs" >&2
  exit 1
fi

if ! lancer "tests de bout en bout" "scripts/tests-e2e.sh"; then
  echo "Suite en cause : tests de bout en bout" >&2
  exit 1
fi

echo
echo "== toutes les suites : OK"
