#!/bin/sh
# Transpositeur global : API HTTP réelle (serveur sur sortie muette), bornes,
# valeur publiée et remise à zéro au redémarrage. Aucun son n'est produit.
# Arrêt par PID (jamais pkill -f), état et port temporaires.
set -u

ulimit -r 0 2>/dev/null || {
  echo "ÉCHEC : ulimit -r 0 impossible ; ne pas lancer le moteur sans temps réel" >&2
  exit 2
}
unset WAYLAND_DISPLAY DISPLAY

RACINE="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$RACINE/build/organum.com"
if [ ! -x "$BIN" ]; then
  echo "ÉCHEC : $BIN absent ou non exécutable (lancer web/scripts/build.sh)" >&2
  exit 2
fi

if [ -z "${ORGANUM_LIBASOUND:-}" ] && [ -d /nix/store ]; then
  CANDIDAT=$(ls /nix/store/*-alsa-lib-*/lib/libasound.so.2 2>/dev/null | sort -V | head -n 1)
  if [ -n "$CANDIDAT" ]; then
    ORGANUM_LIBASOUND="$CANDIDAT"
    export ORGANUM_LIBASOUND
  fi
fi

TMP="$(mktemp -d)" || exit 2
ETAT="$TMP/etat.json"
CONFIG="$TMP/midi.json"
JOURNAL="$TMP/organum.log"
PID=""
ECHECS=0

arreter() {
  if [ -n "$PID" ]; then
    kill -KILL "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
    PID=""
  fi
}

nettoyer() {
  arreter
  rm -rf "$TMP"
}

trap nettoyer EXIT
trap 'nettoyer; exit 130' INT TERM

ok() { echo "OK    : $1"; }
echec() { echo "ÉCHEC : $1"; ECHECS=$((ECHECS + 1)); }

verifie() {
  desc=$1
  motif=$2
  sortie=$3
  if printf '%s' "$sortie" | grep -qF -- "$motif"; then
    ok "$desc"
  else
    echec "$desc (attendu « $motif » ; vu : $sortie)"
  fi
}

port_libre() {
  ! curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$1/api/orgue" 2>/dev/null
}

PORT="${PORT:-8099}"
for p in "$PORT" 8100 8101 8102 8103 8104 8105; do
  if port_libre "$p"; then
    PORT=$p
    break
  fi
done
URL="http://127.0.0.1:$PORT"

lancer() {
  ORGANUM_ETAT="$ETAT" \
  ORGANUM_CONFIG_MIDI="$CONFIG" \
  ORGANUM_FENETRE=non \
  ORGANUM_PERIPHERIQUE=null \
  ORGANUM_QUALITE=3 \
  "$BIN" -l 127.0.0.1 -p "$PORT" >"$JOURNAL" 2>&1 &
  PID=$!
  i=0
  while [ "$i" -lt 200 ]; do
    if curl -s --connect-timeout 1 --max-time 1 -o /dev/null "$URL/api/orgue"; then
      if curl -s "$URL/api/orgue" | grep -qF '"temps_reel":true'; then
        echec "temps réel actif malgré ulimit -r 0"
        arreter
        return 1
      fi
      return 0
    fi
    if ! kill -0 "$PID" 2>/dev/null; then
      echo "ÉCHEC : organum s'est arrêté au démarrage" >&2
      sed 's/^/        /' "$JOURNAL" >&2
      return 1
    fi
    sleep 0.1
    i=$((i + 1))
  done
  echo "ÉCHEC : organum ne répond pas sur $URL" >&2
  sed 's/^/        /' "$JOURNAL" >&2
  return 1
}

get() { curl -s "$URL/api/orgue"; }

post() { curl -s -X POST -H 'Content-Type: application/json' -d "$1" "$URL/api/orgue"; }

code_post() {
  curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' -d "$1" "$URL/api/orgue"
}

champ_num() {
  printf '%s' "$1" | grep -o "\"$2\":-\{0,1\}[0-9]*" | head -n 1 | cut -d: -f2
}

attendre_valeur() {
  attendu=$1
  i=0
  while [ "$i" -lt 40 ]; do
    S=$(get)
    [ "$(champ_num "$S" transposition)" = "$attendu" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

echo "== transposition : démarrage"
lancer || exit 1

S=$(get)
verifie "valeur initiale publiée" '"transposition":0' "$S"

echo "== transposition : réglages valides"
post '{"transposition":3}' >/dev/null
if attendre_valeur 3; then ok "POST +3 publié"; else echec "POST +3 non publié"; fi
post '{"transposition":-2}' >/dev/null
if attendre_valeur -2; then ok "POST -2 publié"; else echec "POST -2 non publié"; fi
for v in -12 12 0; do
  code=$(code_post "{\"transposition\":$v}")
  verifie "POST $v accepté (200)" "200" "$code"
done
if attendre_valeur 0; then ok "retour à 0 publié"; else echec "retour à 0 non publié"; fi

echo "== transposition : bornes et types refusés (400)"
for cas in '{"transposition":-13}' '{"transposition":13}' \
           '{"transposition":1.5}' '{"transposition":"3"}' \
           '{"transposition":true}'; do
  code=$(code_post "$cas")
  verifie "400 pour $cas" "400" "$code"
done
# Une requête refusée ne change pas la valeur en service.
S=$(get)
verifie "valeur inchangée après refus" '"transposition":0' "$S"

echo "== transposition : aucun enregistrement dans etat.json"
post '{"transposition":5}' >/dev/null
attendre_valeur 5 || echec "POST +5 non publié"
# La transposition ne doit jamais entrer dans etat.json. Un simple sommeil
# pouvait laisser passer le battement de sauvegarde (2 s) : on force une
# écriture APRÈS le réglage, en changeant un champ réellement persisté, puis
# on attend que ce champ apparaisse dans le fichier. La vérification porte
# alors sur une sauvegarde certaine, postérieure à la transposition.
post '{"volume":0.25}' >/dev/null
i=0
sauve=0
while [ "$i" -lt 100 ]; do
  if [ -f "$ETAT" ] && grep -qF '"volume":0.25' "$ETAT"; then
    sauve=1
    break
  fi
  sleep 0.1
  i=$((i + 1))
done
if [ "$sauve" -eq 1 ]; then
  ok "etat.json réécrit après le réglage (volume 0,25 enregistré)"
else
  echec "etat.json jamais réécrit après le réglage (${i} dixièmes de seconde, motif \"volume\":0.25 absent)"
fi
if [ -f "$ETAT" ] && grep -q 'transposition' "$ETAT"; then
  echec "etat.json contient une clé transposition"
else
  ok "etat.json sans clé transposition"
fi

echo "== transposition : retour à 0 après redémarrage"
arreter
lancer || exit 1
S=$(get)
verifie "valeur remise à 0 au démarrage" '"transposition":0' "$S"

arreter

echo
if [ "$ECHECS" -eq 0 ]; then
  echo "== transposition : tous les contrôles passent"
  exit 0
fi
echo "== transposition : $ECHECS contrôle(s) en échec"
exit 1
