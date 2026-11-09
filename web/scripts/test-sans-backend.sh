#!/bin/sh
# Test réel du mode dégradé sans backend audio ni MIDI (chemin emprunté par
# macOS) : ORGANUM_SANS_BACKEND=1 sous Linux. Le serveur doit démarrer, servir
# les pages et l'API, publier audio_disponible/midi_disponible à faux, ne
# jamais ouvrir ALSA, et ne lancer aucune boucle de réessai audio.
# Vérifie aussi la non-régression : sans la variable, ou avec la valeur « 0 »,
# le comportement Linux reste normal (périphérique muet « null »).
# Sortie : une ligne OK/ÉCHEC par contrôle ; code de retour non nul si échec.
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
refuse() {
  desc=$1
  motif=$2
  sortie=$3
  if printf '%s' "$sortie" | grep -qF -- "$motif"; then
    echec "$desc (motif interdit « $motif » présent)"
  else
    ok "$desc"
  fi
}

port_libre() {
  ! curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$1/api/orgue" 2>/dev/null
}

PORT="${PORT:-8098}"
for p in "$PORT" 8108 8109 8110 8111 8112; do
  if port_libre "$p"; then
    PORT=$p
    break
  fi
done
URL="http://127.0.0.1:$PORT"

# lancer MODE : MODE vaut degrade, normal ou zero. Démarre l'orgue, attend
# qu'il réponde, et vérifie temps_reel=false (ulimit -r 0).
lancer() {
  mode=$1
  unset ORGANUM_SANS_BACKEND ORGANUM_PERIPHERIQUE
  case "$mode" in
    degrade) export ORGANUM_SANS_BACKEND=1 ;;
    zero)    export ORGANUM_SANS_BACKEND=0 ;;
  esac
  ORGANUM_PERIPHERIQUE=null \
  ORGANUM_ETAT="$ETAT" \
  ORGANUM_CONFIG_MIDI="$CONFIG" \
  ORGANUM_FENETRE=non \
  "$BIN" -l 127.0.0.1 -p "$PORT" >"$JOURNAL" 2>&1 &
  PID=$!
  unset ORGANUM_SANS_BACKEND ORGANUM_PERIPHERIQUE
  i=0
  while [ "$i" -lt 200 ]; do
    if curl -s --connect-timeout 1 --max-time 1 -o /dev/null "$URL/api/orgue"; then
      if curl -s "$URL/api/orgue" | grep -qF '"temps_reel":true'; then
        echec "$mode : temps réel actif malgré ulimit -r 0"
        arreter
        return 1
      fi
      return 0
    fi
    if ! kill -0 "$PID" 2>/dev/null; then
      echec "$mode : organum s'est arrêté au démarrage"
      sed 's/^/        /' "$JOURNAL" >&2
      return 1
    fi
    sleep 0.05
    i=$((i + 1))
  done
  echec "$mode : pas de réponse de l'API dans le délai"
  sed 's/^/        /' "$JOURNAL" >&2
  arreter
  return 1
}

# --- Mode dégradé ----------------------------------------------------------
if lancer degrade; then
  corps=$(curl -s --max-time 2 "$URL/api/orgue")
  verifie "dégradé : audio_disponible faux" '"audio_disponible":false' "$corps"
  verifie "dégradé : midi_disponible faux" '"midi_disponible":false' "$corps"
  verifie "dégradé : mode_degrade vrai" '"mode_degrade":true' "$corps"
  verifie "dégradé : plate-forme linux" '"plateforme":"linux"' "$corps"
  verifie "dégradé : JSON valide" '"divisions"' "$corps"

  for chemin in / /midi /audio; do
    code=$(curl -s -o "$TMP/page.html" -w '%{http_code}' --max-time 2 "$URL$chemin")
    verifie "dégradé : $chemin répond 200" 200 "$code"
  done
  curl -s --max-time 2 "$URL/" > "$TMP/accueil.html"
  verifie "dégradé : / contient le bandeau" 'id="mode-degrade"' "$(cat "$TMP/accueil.html")"
  curl -s --max-time 2 "$URL/audio" > "$TMP/audio.html"
  verifie "dégradé : /audio contient la ligne plate-forme" 'id="qualite-plateforme"' "$(cat "$TMP/audio.html")"

  ports=$(curl -s --max-time 2 "$URL/api/midi/ports")
  verifie "dégradé : MIDI indisponible" '"disponible":false' "$ports"
  verifie "dégradé : aucun port" '"ports":[]' "$ports"

  qualite=$(curl -s --max-time 2 -X POST -H 'Content-Type: application/json' \
    -d '{"qualite":{"periode":1024}}' "$URL/api/orgue")
  verifie "dégradé : changement de période accepté" '"ok":true' "$qualite"
  i=0
  corps=""
  while [ "$i" -lt 40 ]; do
    corps=$(curl -s --max-time 2 "$URL/api/orgue")
    printf '%s' "$corps" | grep -qF '"periode":1024' && break
    sleep 0.05
    i=$((i + 1))
  done
  verifie "dégradé : période publiée" '"periode":1024' "$corps"
  verifie "dégradé : aucune erreur audio" '"audio_erreur":""' "$corps"
  if kill -0 "$PID" 2>/dev/null; then
    ok "dégradé : le serveur vit toujours"
  else
    echec "dégradé : le serveur s'est arrêté"
  fi

  # Aucune ouverture ALSA ni boucle de réessai : le journal doit rester muet
  # sur l'audio, et la consommation CPU rester négligeable.
  sleep 2
  journal=$(cat "$JOURNAL")
  refuse "dégradé : pas de tentative audio dans le journal" 'sortie audio indisponible' "$journal"
  refuse "dégradé : pas de message ALSA" 'ALSA' "$journal"
  refuse "dégradé : pas de message SCHED_FIFO" 'SCHED_FIFO' "$journal"
  # GET /api/midi/ports a déjà eu lieu : en mode dégradé, l'absence de
  # séquenceur n'est pas un orgue non démarré et ne doit pas être annoncée
  # comme telle.
  refuse "dégradé : MIDI non ouvert, pas « organum non démarré »" \
    'organum non démarré' "$journal"
  # ps -o %cpu donne une moyenne depuis le lancement, dominée par le
  # chargement du moteur. Mesurer la consommation réelle sur 2 s par les
  # compteurs de temps CPU de /proc : une boucle de réessai se verrait.
  ticks() { awk '{print $14 + $15}' "/proc/$PID/stat" 2>/dev/null || echo 0; }
  hz=$(getconf CLK_TCK 2>/dev/null || echo 100)
  avant=$(ticks)
  sleep 2
  apres=$(ticks)
  delta=$((apres - avant))
  [ "$delta" -ge 0 ] || delta=0
  cpu_pct=$((delta * 100 / (hz * 2)))
  if [ "$cpu_pct" -le 20 ]; then
    ok "dégradé : consommation CPU au repos faible (${cpu_pct}%)"
  else
    echec "dégradé : consommation CPU au repos anormale (${cpu_pct}%)"
  fi
  arreter
fi

# --- Non-régression : comportement Linux normal ----------------------------
# Sans séquenceur ALSA (runner de CI sans carte son), le backend MIDI normal
# ne peut pas s'ouvrir : ces contrôles sont hors de portée. Le mode dégradé
# ci-dessus reste entièrement exercé, et les autres suites de la CI forcent
# le backend socket. En local, avec /dev/snd/seq, tout est vérifié.
if [ -n "${ORGANUM_TESTS_SANS_ALSA_MIDI:-}" ]; then
  echo "IGNORÉ : non-régression ALSA normale (séquenceur MIDI absent)"
else
  if lancer normal; then
    corps=$(curl -s --max-time 2 "$URL/api/orgue")
    verifie "normal : audio_disponible vrai" '"audio_disponible":true' "$corps"
    verifie "normal : midi_disponible vrai" '"midi_disponible":true' "$corps"
    verifie "normal : mode_degrade faux" '"mode_degrade":false' "$corps"
    ports=$(curl -s --max-time 2 "$URL/api/midi/ports")
    verifie "normal : MIDI disponible" '"disponible":true' "$ports"
    # Backend ALSA : aucun assistant à lancer, la page /midi ne doit pas
    # proposer organum-midi (elle teste etatPorts.socket === true).
    verifie "normal : backend non socket annoncé" '"socket":false' "$ports"
    arreter
  fi

  if lancer zero; then
    corps=$(curl -s --max-time 2 "$URL/api/orgue")
    verifie "ORGANUM_SANS_BACKEND=0 : audio_disponible vrai" '"audio_disponible":true' "$corps"
    verifie "ORGANUM_SANS_BACKEND=0 : mode_degrade faux" '"mode_degrade":false' "$corps"
    arreter
  fi
fi

if [ "$ECHECS" -ne 0 ]; then
  echo "-- $ECHECS échec(s)"
  exit 1
fi
echo "-- mode dégradé : tous les contrôles passent"
exit 0
