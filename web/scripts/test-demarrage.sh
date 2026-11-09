#!/bin/sh
# Test de non-régression du délai de première réponse HTTP.
#
# redbean génère un certificat TLS auto-signé entre Listen() et EventLoop(),
# en reverse-résolvant chaque adresse non-loopback ; sous XNU, 0.0.0.0 coûtait
# ~34 s, pendant lesquelles le port écoutait sans accept(). organum passe donc
# -X sous XNU seulement (sauf -C/-K) ; Linux et Windows gardent TLS. Le test
# lance le serveur réel, sonde /api/orgue toutes les 50 ms et exige une
# première réponse en moins de 10 s (référence : ~1 s sous Linux, ~4 s sous
# macOS avec -X, contre ~38 s avant le correctif). Il vérifie aussi le
# certificat : absent sous XNU (-X), généré ailleurs (TLS conservé).
# Sortie : une ligne OK/ÉCHEC par contrôle ; code non nul si échec.
set -u

ulimit -r 0 2>/dev/null || {
  # macOS refuse d'abaisser cette limite ; il n'y a de toute façon aucun
  # backend audio, donc pas de fil temps réel à protéger. Le test doit
  # pouvoir y tourner, c'est là que le défaut de démarrage se produisait.
  if [ "$(uname -s)" != Darwin ]; then
    echo "ÉCHEC : ulimit -r 0 impossible ; ne pas lancer le moteur sans temps réel" >&2
    exit 2
  fi
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

port_libre() {
  ! curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$1/api/orgue" 2>/dev/null
}

PORT="${PORT:-8097}"
for p in "$PORT" 8107 8117 8127 8137 8147; do
  if port_libre "$p"; then
    PORT=$p
    break
  fi
done
URL="http://127.0.0.1:$PORT"

# -v -v : le journal montre la génération du certificat auto-signé quand TLS
# est actif. ORGANUM_QUALITE=3 évite la calibration automatique.
ORGANUM_PERIPHERIQUE=null \
ORGANUM_ETAT="$ETAT" \
ORGANUM_CONFIG_MIDI="$CONFIG" \
ORGANUM_FENETRE=non \
ORGANUM_QUALITE=3 \
"$BIN" -v -v -l 127.0.0.1 -p "$PORT" >"$JOURNAL" 2>&1 &
PID=$!

debut=$(date +%s)
i=0
repondu=0
while [ "$i" -lt 200 ]; do
  if curl -s --connect-timeout 1 --max-time 1 -o /dev/null "$URL/api/orgue"; then
    repondu=1
    break
  fi
  if ! kill -0 "$PID" 2>/dev/null; then
    echo "ÉCHEC : organum s'est arrêté au démarrage" >&2
    sed 's/^/        /' "$JOURNAL" >&2
    exit 1
  fi
  maintenant=$(date +%s)
  if [ $((maintenant - debut)) -ge 10 ]; then
    break
  fi
  sleep 0.05
  i=$((i + 1))
done
duree=$(( $(date +%s) - debut ))

if [ "$repondu" -eq 1 ] && [ "$duree" -lt 10 ]; then
  ok "première réponse HTTP en ${duree} s (< 10 s)"
else
  echec "première réponse HTTP absente ou tardive (${duree} s ; borne 10 s)"
  sed 's/^/        /' "$JOURNAL" >&2
  exit 1
fi

if [ "$(uname -s)" = Darwin ]; then
  # XNU : -X doit avoir coupé TLS (c'est tout l'objet du contournement).
  if grep -q "generating self-signed ssl certificates" "$JOURNAL"; then
    echec "génération d'un certificat TLS malgré -X sous XNU"
  else
    ok "aucune génération de certificat TLS (XNU, -X)"
  fi
else
  # Linux/Windows : comportement d'origine, TLS doit rester actif.
  if grep -q "generating self-signed ssl certificates" "$JOURNAL"; then
    ok "certificat TLS auto-signé généré (TLS conservé hors XNU)"
  else
    echec "aucune génération de certificat TLS hors XNU (TLS perdu)"
    sed 's/^/        /' "$JOURNAL" >&2
    exit 1
  fi
fi

for chemin in / /midi /audio; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$URL$chemin")
  if [ "$code" = 200 ]; then
    ok "page $chemin : 200"
  else
    echec "page $chemin : $code"
  fi
done

S=$(curl -s --max-time 2 "$URL/api/orgue")
if printf '%s' "$S" | grep -qF '"divisions"'; then
  ok "API /api/orgue cohérente"
else
  echec "API /api/orgue incohérente : $S"
fi

if [ "$ECHECS" -eq 0 ]; then
  echo "Tous les contrôles : OK"
  exit 0
fi
echo "$ECHECS contrôle(s) en échec"
exit 1
