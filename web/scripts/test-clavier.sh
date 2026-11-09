#!/bin/sh
# Clavier jouable de la page d'orgue : API HTTP réelle (serveur sur sortie
# muette). Une note injectée par POST /api/orgue {note} doit allumer le canal
# dans canaux_actifs, puis l'éteindre après le relâchement (~250 ms). Les
# messages mal formés, les notes hors 0..127 et les canaux hors 1..16 doivent
# donner 400 sans arrêter le serveur. Aucun son n'est produit.
#
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

code_post() {
  curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' -d "$1" "$URL/api/orgue"
}

post() { curl -s -o /dev/null -X POST -H 'Content-Type: application/json' -d "$1" "$URL/api/orgue"; }

canaux_actifs() {
  curl -s "$URL/api/midi" | grep -o '"canaux_actifs":\[[^]]*\]' | head -n 1
}

attendre_canaux() {
  motif=$1
  i=0
  while [ "$i" -lt 50 ]; do
    C=$(canaux_actifs)
    case "$C" in
      *"$motif"*) return 0 ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

echo "== clavier : démarrage"
lancer || exit 1

verifie "aucun canal actif au départ" '"canaux_actifs":[]' "$(canaux_actifs)"

echo "== clavier : note tenue puis relâchée"
code=$(code_post '{"note":{"canal":1,"note":60,"velocite":100,"actif":true}}')
verifie "note ON acceptée (200)" "200" "$code"
if attendre_canaux '1'; then
  ok "canal 1 actif après note ON"
else
  echec "canal 1 non actif après note ON ($(canaux_actifs))"
fi
code=$(code_post '{"note":{"canal":1,"note":60,"velocite":0,"actif":false}}')
verifie "note OFF acceptée (200)" "200" "$code"
if attendre_canaux '"canaux_actifs":[]'; then
  ok "canal 1 éteint après note OFF"
else
  echec "canal 1 toujours actif après note OFF ($(canaux_actifs))"
fi

echo "== clavier : bornes valides"
for cas in \
  '{"note":{"canal":1,"note":0,"velocite":1,"actif":true}}' \
  '{"note":{"canal":16,"note":127,"velocite":127,"actif":true}}' \
  '{"note":{"canal":16,"note":127,"actif":false}}' \
  '{"note":{"canal":1,"note":60,"velocite":0,"actif":true}}'; do
  code=$(code_post "$cas")
  verifie "200 pour $cas" "200" "$code"
done
# Toujours aucun plantage ni état bloqué.
post '{"note":{"canal":1,"note":60,"actif":false}}'
if attendre_canaux '"canaux_actifs":[]'; then
  ok "canaux éteints après les bornes"
else
  echec "canaux non éteints après les bornes ($(canaux_actifs))"
fi

echo "== clavier : messages mal formés, notes et canaux refusés (400)"
for cas in \
  '{"note":[]}' \
  '{"note":"do"}' \
  '{"note":{}}' \
  '{"note":{"canal":1,"note":60}}' \
  '{"note":{"canal":1,"note":60,"actif":true,"extra":1}}' \
  '{"note":{"canal":0,"note":60,"actif":true}}' \
  '{"note":{"canal":17,"note":60,"actif":true}}' \
  '{"note":{"canal":1.5,"note":60,"actif":true}}' \
  '{"note":{"canal":"1","note":60,"actif":true}}' \
  '{"note":{"canal":1,"note":-1,"actif":true}}' \
  '{"note":{"canal":1,"note":128,"actif":true}}' \
  '{"note":{"canal":1,"note":60.5,"actif":true}}' \
  '{"note":{"canal":1,"note":"60","actif":true}}' \
  '{"note":{"canal":1,"note":60,"velocite":-1,"actif":true}}' \
  '{"note":{"canal":1,"note":60,"velocite":128,"actif":true}}' \
  '{"note":{"canal":1,"note":60,"velocite":1.5,"actif":true}}' \
  '{"note":{"canal":1,"note":60,"actif":"oui"}}' \
  '{"note":{"canal":1,"note":60,"actif":1}}' \
  '{"note":{"canal":1,"note":60,"actif":true},"panic":true}'; do
  code=$(code_post "$cas")
  verifie "400 pour $cas" "400" "$code"
done
verifie "aucune note allumée par les refus" '"canaux_actifs":[]' "$(canaux_actifs)"
S=$(curl -s "$URL/api/orgue")
verifie "serveur toujours vivant après les refus" '"source":"aeolus"' "$S"

arreter

echo
if [ "$ECHECS" -eq 0 ]; then
  echo "== clavier : tous les contrôles passent"
  exit 0
fi
echo "== clavier : $ECHECS contrôle(s) en échec"
exit 1
