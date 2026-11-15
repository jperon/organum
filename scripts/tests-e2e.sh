#!/usr/bin/env bash
# Tests de bout en bout : interface web (Chromium headless, protocole
# DevTools via Node) et interface native (Xvfb + xdotool), puis vérification
# que deux régressions connues sont bien détectées (mutation temporaire).
#
#   scripts/tests-e2e.sh
#
# Sûreté : aucun affichage réel, aucune sortie audio réelle, aucun réglage de
# l'utilisateur. Tout est lancé sur des ports libres et des dossiers
# temporaires, puis arrêté par PID (même en cas d'échec).
set -u

# Sûreté : pas de temps réel, pas de Wayland hérité, pas d'affichage hérité.
ulimit -r 0 2>/dev/null || {
  echo "ÉCHEC : ulimit -r 0 impossible ; ne pas lancer le moteur sans temps réel" >&2
  exit 2
}
unset WAYLAND_DISPLAY DISPLAY

RACINE="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$RACINE/web/build/organum.com"
TMP="$(mktemp -d)" || exit 2
if [ -n "${ORGANUM_CAPTURES:-}" ]; then
  CAPTURES="$ORGANUM_CAPTURES"
  mkdir -p "$CAPTURES" || exit 2
else
  CAPTURES="$(mktemp -d)" || exit 2
fi
mkdir -p "$TMP/lua" "$TMP/bin"
ECHECS=0
IGNORES=0
OKS=0
DEBUT_NS=$(date +%s%N)
PID_ORGANUM=""
PID_CHROMIUM=""
PID_XVFB=""
WID=""
DISPLAY_NUM=""
MUTATION_ACTIVE=0

duree() {
  printf '%s.%03d s' "$(( ($2 - $1) / 1000000000 ))" "$(( (($2 - $1) / 1000000) % 1000 ))"
}

ok() {
  OKS=$((OKS + 1))
  echo "OK    : $1"
}

echec() {
  ECHECS=$((ECHECS + 1))
  echo "ÉCHEC : $1"
}

ignore() {
  IGNORES=$((IGNORES + 1))
  echo "IGNORÉ : $1"
}

# Tue récursivement un arbre de processus par PID, sans jamais viser un nom.
tuer_arbre() {
  pid=$1
  [ -n "$pid" ] || return 0
  for enfant in $(pgrep -P "$pid" 2>/dev/null || true); do
    tuer_arbre "$enfant"
  done
  kill -KILL "$pid" 2>/dev/null || true
  kill -KILL -- "-$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

arreter_organum() {
  if [ -n "$PID_ORGANUM" ]; then
    tuer_arbre "$PID_ORGANUM"
    PID_ORGANUM=""
  fi
  # Le lanceur APE peut se ré-exécuter et laisser le vrai serveur orphelin
  # (parent reparenté à 1). On le retrouve par sa ligne de commande exacte
  # (binaire + port), puis on tue son arbre et son groupe par PID.
  if [ -n "${PORT:-}" ]; then
    for d in /proc/[0-9]*; do
      [ -r "$d/cmdline" ] || continue
      cmd=$(tr '\0' ' ' <"$d/cmdline" 2>/dev/null || true)
      case "$cmd" in
        *"$BIN"*"-p $PORT "*) tuer_arbre "${d#/proc/}" ;;
      esac
    done
  fi
  WID=""
}

arreter_chromium() {
  if [ -n "$PID_CHROMIUM" ]; then
    tuer_arbre "$PID_CHROMIUM"
    PID_CHROMIUM=""
  fi
  # Chromium se détache en plusieurs zygotes dont le parent peut disparaître :
  # on les retrouve par leur profil temporaire unique, puis on tue par PID.
  for d in /proc/[0-9]*; do
    [ -r "$d/cmdline" ] || continue
    cmd=$(tr '\0' ' ' <"$d/cmdline" 2>/dev/null || true)
    case "$cmd" in
      *"$TMP/profil-chromium"*) tuer_arbre "${d#/proc/}" ;;
    esac
  done
  # Second passage : les zygotes peuvent être reparentés entre-temps. pgrep -f
  # ne sert qu'à obtenir des PID, jamais à tuer par motif.
  for p in $(pgrep -f -- "$TMP/profil-chromium" 2>/dev/null || true); do
    tuer_arbre "$p"
  done
  for p in $(pgrep -f -- "$TMP/profil-chromium" 2>/dev/null || true); do
    kill -KILL "$p" 2>/dev/null || true
  done
}

arreter_xvfb() {
  if [ -n "$PID_XVFB" ]; then
    # SIGTERM d'abord : Xvfb retire alors lui-même son verrou et sa socket.
    # SIGKILL (tuer_arbre) les laisserait derrière lui et saturerait la plage.
    kill -TERM "$PID_XVFB" 2>/dev/null || true
    for _ in $(seq 1 50); do
      kill -0 "$PID_XVFB" 2>/dev/null || break
      sleep 0.1
    done
    if kill -0 "$PID_XVFB" 2>/dev/null; then
      tuer_arbre "$PID_XVFB"
    else
      wait "$PID_XVFB" 2>/dev/null || true
    fi
    PID_XVFB=""
  fi
  # Ne retirer que le numéro pris par CE script, jamais un écran hors plage
  # ni celui d'un processus encore vivant.
  if [ -n "$DISPLAY_NUM" ] && [ "$DISPLAY_NUM" -ge 90 ] && [ "$DISPLAY_NUM" -le 139 ]; then
    rm -f "/tmp/.X$DISPLAY_NUM-lock" "/tmp/.X11-unix/X$DISPLAY_NUM"
    DISPLAY_NUM=""
  fi
  unset DISPLAY
}

restaurer_mutation() {
  if [ "$MUTATION_ACTIVE" -eq 1 ]; then
    cp "$TMP/page_audio.moon.orig" "$RACINE/web/src/page_audio.moon" 2>/dev/null || true
    cp "$TMP/fenetre.moon.orig" "$RACINE/web/src/fenetre.moon" 2>/dev/null || true
    MUTATION_ACTIVE=0
  fi
}

nettoyer() {
  arreter_organum
  arreter_chromium
  arreter_xvfb
  restaurer_mutation
  rm -rf "$TMP"
}

trap nettoyer EXIT
trap 'nettoyer; exit 130' INT TERM

port_libre() {
  ! curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$1/api/orgue" 2>/dev/null
}

trouver_port() {
  p=${1:-$((18000 + ($$ % 1000)))}
  while ! port_libre "$p"; do
    p=$((p + 1))
  done
  printf '%s' "$p"
}

# Écrit un faux wpctl : volume et sourdine dans un fichier temporaire, jamais
# sur le serveur audio de l'utilisateur.
creer_faux_wpctl() {
  ETAT_VOLUME="$TMP/faux-volume"
  printf '0.50\n0\n' >"$ETAT_VOLUME"
  cat >"$TMP/bin/wpctl" <<WPC
#!/bin/sh
etat="$ETAT_VOLUME"
vol=\$(sed -n 1p "\$etat" 2>/dev/null || echo 0.50)
muet=\$(sed -n 2p "\$etat" 2>/dev/null || echo 0)
# Lecture tolérante : un autre processus peut avoir tronqué le fichier
# entre deux commandes ; une valeur vide retombe sur le défaut.
[ -n "\$vol" ] || vol=0.50
[ -n "\$muet" ] || muet=0
case "\$1" in
  get-volume)
    if [ "\$muet" = 1 ]; then echo "Volume: \$vol [MUTED]"; else echo "Volume: \$vol"; fi
    ;;
  set-volume)
    printf '%s\n%s\n' "\$3" "\$muet" >"\$etat.tmp.\$\$"; mv "\$etat.tmp.\$\$" "\$etat"
    echo "Volume: \$3"
    ;;
  set-mute)
    printf '%s\n%s\n' "\$vol" "\$3" >"\$etat.tmp.\$\$"; mv "\$etat.tmp.\$\$" "\$etat"
    echo "Volume: \$vol"
    ;;
  *) exit 1 ;;
esac
WPC
  chmod +x "$TMP/bin/wpctl"
}

# Un verrou X est périmé quand son PID n'existe plus. On ne supprime que ce
# cas : un verrou de processus vivant (ou illisible) bloque toujours le numéro.
verrou_xvfb_obsolete() {
  n=$1
  verrou="/tmp/.X$n-lock"
  [ -e "$verrou" ] || return 1
  pid=$(sed -n '1{s/^[^0-9]*//;s/[^0-9].*//;p;}' "$verrou" 2>/dev/null)
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null && return 1
  return 0
}

demarrer_xvfb() {
  if ! command -v Xvfb >/dev/null 2>&1; then
    return 1
  fi
  DISPLAY_NUM=""
  for n in $(seq 90 139); do
    # Une socket existante signale un écran occupé : ne jamais y toucher.
    [ -e "/tmp/.X11-unix/X$n" ] && continue
    if [ -e "/tmp/.X$n-lock" ]; then
      verrou_xvfb_obsolete "$n" || continue
      # Verrou périmé : Xvfb sait aussi le remplacer, mais le retirer ici
      # évite qu'un arrêt brutal laisse le numéro bloqué pour les suivants.
      rm -f "/tmp/.X$n-lock"
    fi
    DISPLAY_NUM=$n
    break
  done
  if [ -z "$DISPLAY_NUM" ]; then
    echo "ÉCHEC : plage d'écrans Xvfb 90..139 saturée (verrous ou sockets occupés)" >&2
    return 1
  fi
  Xvfb ":$DISPLAY_NUM" -screen 0 1920x1080x24 -listen tcp -ac \
    >"$TMP/xvfb.log" 2>&1 &
  PID_XVFB=$!
  export DISPLAY=":$DISPLAY_NUM"
  for _ in $(seq 1 50); do
    timeout 1 xdotool getdisplaygeometry >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  arreter_xvfb
  return 1
}

# demarrer_organum <avec_fenetre oui|non>
# Avec la fenêtre, le volume système vient du faux wpctl de $TMP/bin : la
# fenêtre affiche alors les deux curseurs généraux (Volume et Pédale) comme
# sur un poste réel, sans jamais toucher au volume de l'utilisateur.
demarrer_organum() {
  fenetre=$1
  PORT=$(trouver_port)
  URL="http://127.0.0.1:$PORT"
  ETAT="$TMP/etat-$PORT.json"
  CONFIG="$TMP/midi-$PORT.json"
  JOURNAL="$TMP/organum-$PORT.log"
  if [ "$fenetre" = oui ]; then
    setsid env -u ORGANUM_FENETRE -u WAYLAND_DISPLAY \
      PATH="$TMP/bin:$PATH" ORGANUM_VOLUME=wpctl \
      ORGANUM_PERIPHERIQUE=null ORGANUM_QUALITE=3 \
      ORGANUM_ETAT="$ETAT" ORGANUM_CONFIG_MIDI="$CONFIG" \
      DISPLAY="$DISPLAY" "$BIN" -l 127.0.0.1 -p "$PORT" >"$JOURNAL" 2>&1 &
  else
    setsid env -u DISPLAY -u WAYLAND_DISPLAY ORGANUM_FENETRE=non \
      PATH="$TMP/bin:$PATH" ORGANUM_VOLUME=wpctl ORGANUM_PERIPHERIQUE=null \
      ORGANUM_QUALITE=3 ORGANUM_ETAT="$ETAT" ORGANUM_CONFIG_MIDI="$CONFIG" \
      "$BIN" -l 127.0.0.1 -p "$PORT" >"$JOURNAL" 2>&1 &
  fi
  PID_ORGANUM=$!
  for _ in $(seq 1 300); do
    if curl -s --connect-timeout 1 --max-time 1 -o /dev/null "$URL/api/orgue"; then
      if curl -s "$URL/api/orgue" | grep -qF '"temps_reel":true'; then
        echo "ÉCHEC : temps réel actif malgré ulimit -r 0" >&2
        arreter_organum
        return 1
      fi
      return 0
    fi
    if ! kill -0 "$PID_ORGANUM" 2>/dev/null; then
      echo "ÉCHEC : organum s'est arrêté au démarrage" >&2
      sed 's/^/        /' "$JOURNAL" >&2
      return 1
    fi
    sleep 0.1
  done
  echo "ÉCHEC : organum ne répond pas sur $URL" >&2
  sed 's/^/        /' "$JOURNAL" >&2
  return 1
}

# Serveur avec mot de passe, pour l'e2e de l'authentification : écoute sur
# toutes les interfaces afin qu'une adresse non locale de l'hôte soit
# utilisée par Chromium (127.0.0.1 est exempté).
demarrer_organum_auth() {
  PORT=$(trouver_port $((18100 + ($$ % 300))))
  URL="http://$HOTE_AUTH:$PORT"
  ETAT="$TMP/etat-auth-$PORT.json"
  CONFIG="$TMP/midi-auth-$PORT.json"
  AUTH="$ETAT.digest"
  JOURNAL="$TMP/organum-auth-$PORT.log"
  HA1=$(printf 'organiste:organum:%s' 'secret01' | sha256sum | cut -d' ' -f1)
  printf 'organiste:organum:%s\n' "$HA1" >"$AUTH"
  chmod 600 "$AUTH"
  setsid env -u DISPLAY -u WAYLAND_DISPLAY ORGANUM_FENETRE=non \
    PATH="$TMP/bin:$PATH" ORGANUM_VOLUME=wpctl ORGANUM_PERIPHERIQUE=null \
    ORGANUM_QUALITE=3 ORGANUM_ETAT="$ETAT" ORGANUM_CONFIG_MIDI="$CONFIG" \
    ORGANUM_DIGEST="$AUTH" \
    "$BIN" -p "$PORT" >"$JOURNAL" 2>&1 &
  PID_ORGANUM=$!
  for _ in $(seq 1 300); do
    if curl -s --connect-timeout 1 --max-time 1 -o /dev/null "http://127.0.0.1:$PORT/api/orgue"; then
      if curl -s "http://127.0.0.1:$PORT/api/orgue" | grep -qF '"temps_reel":true'; then
        echo "ÉCHEC : temps réel actif malgré ulimit -r 0" >&2
        arreter_organum
        return 1
      fi
      return 0
    fi
    if ! kill -0 "$PID_ORGANUM" 2>/dev/null; then
      echo "ÉCHEC : organum (authentification) s'est arrêté au démarrage" >&2
      sed 's/^/        /' "$JOURNAL" >&2
      return 1
    fi
    sleep 0.1
  done
  echo "ÉCHEC : organum (authentification) ne répond pas" >&2
  sed 's/^/        /' "$JOURNAL" >&2
  return 1
}

demarrer_chromium() {
  # Profil neuf à chaque lancement : le SingletonLock du précédent empêcherait
  rm -rf "$TMP/profil-chromium"
  CDP_PORT=$(trouver_port $((PORT + 300)))
  env -u LD_LIBRARY_PATH -u DISPLAY -u WAYLAND_DISPLAY \
    chromium --headless=new --no-sandbox --disable-gpu \
    --disable-dev-shm-usage --remote-debugging-port="$CDP_PORT" \
    --user-data-dir="$TMP/profil-chromium" --window-size=1100,900 \
    about:blank >"$TMP/chromium.log" 2>&1 &
  PID_CHROMIUM=$!
  for _ in $(seq 1 100); do
    if curl -s --max-time 1 "http://127.0.0.1:$CDP_PORT/json/version" >/dev/null; then
      return 0
    fi
    if ! kill -0 "$PID_CHROMIUM" 2>/dev/null; then
      return 1
    fi
    sleep 0.1
  done
  return 1
}

attendre_fenetre() {
  for _ in $(seq 1 150); do
    WID=$(xdotool search --name '^organum$' 2>/dev/null | head -n 1)
    [ -n "$WID" ] && return 0
    sleep 0.1
  done
  return 1
}

redimensionner() {
  xdotool windowsize "$WID" "$1" "$2"
  sleep 1
}

capturer() {
  import -display "$DISPLAY" -window "$WID" "$CAPTURES/$1.png" 2>/dev/null
}

clic_xy() {
  # Pression et relâchement séparés : sans gestionnaire de fenêtres et avec
  # Nuklear, un clic instantané peut n'être lu que comme un survol.
  xdotool mousemove --window "$WID" "$1" "$2"
  sleep 0.08
  xdotool mousedown 1
  sleep 0.15
  xdotool mouseup 1
  sleep 0.4
}

glisser_xy() {
  xdotool mousemove --window "$WID" "$1" "$2"
  sleep 0.08
  xdotool mousedown 1
  sleep 0.15
  xdotool mousemove --window "$WID" "$3" "$4"
  sleep 0.15
  xdotool mouseup 1
  sleep 0.5
}

lire_api() {
  curl -s "$URL/api/orgue"
}

# attendre_api <motif littéral> <délai en dixièmes>
attendre_api() {
  for _ in $(seq 1 "$2"); do
    S=$(lire_api)
    printf '%s' "$S" | grep -qF -- "$1" && return 0
    sleep 0.1
  done
  return 1
}

ecrire_json_api() {
  curl -s -X POST -H 'Content-Type: application/json' -d "$1" "$URL/api/orgue" >/dev/null
}

# attendre_valeur <expression python sur l'état> <cible> <tolérance> <dixièmes>
# Compare une valeur numérique de /api/orgue à une cible, avec tolérance :
# une valeur glissée n'est jamais exactement ronde.
attendre_valeur() {
  expression=$1; cible=$2; tolerance=$3; dixiemes=$4
  for _ in $(seq 1 "$dixiemes"); do
    lire_api >"$TMP/valeur.json"
    if python3 - "$TMP/valeur.json" "$cible" "$tolerance" "$expression" <<'PY'
import json, sys
e = json.load(open(sys.argv[1]))
cible, tolerance = float(sys.argv[2]), float(sys.argv[3])
valeur = eval(sys.argv[4], {"e": e})
sys.exit(0 if abs(float(valeur) - cible) <= tolerance else 1)
PY
    then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

# Coordonnées calculées par fenetre_disposition, jamais codées en dur.
# coords <mode> <largeur> <hauteur> [paramètres...]
coords() {
  mode=$1
  l=$2
  h=$3
  shift 3
  case "$mode" in
    console)
      R1=$1; R2=$2
      L="$l" H="$h" MODE=console R1="$R1" R2="$R2" \
        NDIV="${NDIV:-1}" MAXJEUX="${MAXJEUX:-10}" LIENS="${LIENS:-0}" COL="${COL:-0}" \
        UNIT_LUA_PATH="$TMP/lua/?.lua" redbean -i "$TMP/coords.lua"
      ;;
    qualite)
      rows=$1; cols=$2; frac=${3:-0.25}; per=${4:-5}
      L="$l" H="$h" MODE=qualite ROWS="$rows" COLS="$cols" REVERB_FRAC="$frac" PERIODE_ROW="$per" \
        UNIT_LUA_PATH="$TMP/lua/?.lua" redbean -i "$TMP/coords.lua"
      ;;
    midi)
      ndiv=$1; nassoc=$2
      L="$l" H="$h" MODE=midi NDIV="$ndiv" NASSOC="$nassoc" \
        UNIT_LUA_PATH="$TMP/lua/?.lua" redbean -i "$TMP/coords.lua"
      ;;
    connexions)
      nports=$1
      L="$l" H="$h" MODE=connexions NPORTS="$nports" \
        UNIT_LUA_PATH="$TMP/lua/?.lua" redbean -i "$TMP/coords.lua"
      ;;
  esac
}

# Paramètres de disposition déduits de l'état réel.
parametres_qualite() {
  lire_api >"$TMP/api.json"
  python3 - "$TMP/api.json" <<'PY'
import json, sys
e = json.load(open(sys.argv[1]))
q = e.get("qualite", {})
# Le panneau natif lit la réverbération dans etat (e.reverb), pas dans qualite.
a_reverb = 1 if isinstance(e.get("reverb"), (int, float)) else 0
a_tete = 1 if (isinstance(q.get("tete_reverb"), bool) and isinstance(q.get("tete_reverb_prochain"), bool)) else 0
a_calib = 1 if isinstance(q.get("calibration"), dict) else 0
rows = 10 + a_reverb + a_tete + a_calib + 1 + 1 + 1 + 1
cols = 6 if isinstance(q.get("auto"), bool) else 5
per = 6 if a_reverb else 5
print(rows, cols, per)
PY
}

parametres_console() {
  lire_api >"$TMP/api.json"
  python3 - "$TMP/api.json" <<'PY'
import json, sys
e = json.load(open(sys.argv[1]))
noms = [j.get("name", "") for d in e.get("divisions", []) for j in d.get("stops", [])]
r1 = max([len(n) for n in noms] or [8]) * 0.5
r2 = r1 * 0.75
print(f"{r1:.3f} {r2:.3f}")
PY
}

parametres_transposition() {
  lire_api >"$TMP/api.json"
  python3 - "$TMP/api.json" <<'PY'
import json, sys
e = json.load(open(sys.argv[1]))
divs = e.get("divisions", [])
maxjeux = max([len(d.get("stops", [])) for d in divs] or [10])
liens = 1 if any(d.get("links") for d in divs) else 0
piano = 1 if e.get("piano_disponible") is True else 0
print(len(divs), maxjeux, liens, piano)
PY
}

# Nombre d'accouplements d'une division, depuis l'état publié.
liens_division() {
  lire_api | python3 -c 'import json,sys
e = json.load(sys.stdin)
print(len(e["divisions"][int(sys.argv[1])].get("links") or {}))' "$1"
}

parametres_midi() {
  lire_api >"$TMP/api.json"
  curl -s "$URL/api/midi" >"$TMP/midi.json"
  python3 - "$TMP/api.json" "$TMP/midi.json" <<'PY'
import json, sys
e = json.load(open(sys.argv[1]))
m = json.load(open(sys.argv[2]))
print(len(e.get("divisions", [])), len(m.get("associations", [])))
PY
}

parametres_connexions() {
  curl -s "$URL/api/midi/ports" >"$TMP/ports.json"
  python3 - "$TMP/ports.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
print(len(p.get("ports", [])))
PY
}

# stabilité : seq et « on » identiques après 5 s.
stable_etat() {
  nom=$1
  lire_api >"$TMP/stable-1.json"
  sleep 5
  lire_api >"$TMP/stable-2.json"
  if python3 - "$TMP/stable-1.json" "$TMP/stable-2.json" <<'PY'
import json, sys
a = json.load(open(sys.argv[1]))
b = json.load(open(sys.argv[2]))
def jeux(e):
    return [bool(j.get("on")) for d in e.get("divisions", []) for j in d.get("stops", [])]
if a.get("seq") != b.get("seq") or jeux(a) != jeux(b):
    print("seq %s -> %s" % (a.get("seq"), b.get("seq")))
    sys.exit(1)
sys.exit(0)
PY
  then
    ok "$nom : état stable sans action pendant 5 s"
  else
    echec "$nom : état instable sans action"
  fi
}

ecrire_helper_lua() {
  moonc -o "$TMP/lua/fenetre_disposition.lua" \
    "$RACINE/web/src/fenetre_disposition.moon" || return 1
  cat >"$TMP/coords.lua" <<'LUA'
package.path = (os.getenv("UNIT_LUA_PATH") or "") .. ";" .. package.path
local d = require "fenetre_disposition"
local l = tonumber(os.getenv("L")) or 1024
local h = tonumber(os.getenv("H")) or 640
local mode = os.getenv("MODE")
local MARGE, ESPACE = d.MARGE, d.ESPACE
local function arrondi(x) return math.floor(x + 0.5) end
local function colonne(n, c)
  local w = (l - 2 * MARGE - ESPACE * (n - 1)) / n
  return MARGE + c * (w + ESPACE) + w / 2, w
end
local function ligne_y(k, hauteur)
  return MARGE + ESPACE + k * (hauteur + ESPACE) + hauteur / 2
end
if mode == "console" then
  local r1 = tonumber(os.getenv("R1") or "8")
  local r2 = tonumber(os.getenv("R2") or "6")
  local cible = math.min(d.POLICE_MAX, math.max(13, math.floor(l / 64)))
  local ndiv = tonumber(os.getenv("NDIV") or "1")
  local maxjeux = tonumber(os.getenv("MAXJEUX") or "10")
  local a_liens = os.getenv("LIENS") == "1"
  local nb = tonumber(os.getenv("GENERAUX") or "2")
  -- Piano : le bouton existe quand le SoundFont est chargé (PIANO=1) ; NLIENS
  -- est le nombre d'accouplements de la colonne visée, 0 pour le clavier qui
  -- porte la transposition.
  local piano = os.getenv("PIANO") == "1"
  local nliens = tonumber(os.getenv("NLIENS") or "0")
  local divisions = {}
  for i = 1, ndiv do
    local jeux = {}
    for j = 1, maxjeux do jeux[j] = {} end
    divisions[i] = {jeux = jeux, liens = (a_liens and i > 1) and {{}} or {}}
  end
  local p = d.disposer({divisions = divisions, netapes = 32}, l, h, r1, r2, cible, nb)
  -- Rangée des réglages : Panique, Audio, MIDI, puis trois cases vides ;
  -- boutons compacts sur six colonnes égales.
  local y = arrondi(d.rangee_y(0, p.entete))
  print("panique_x=" .. arrondi(d.case_centre(d.MARGE, l - 2 * d.MARGE, 6, 0))); print("panique_y=" .. y)
  print("audio_x=" .. arrondi(d.case_centre(d.MARGE, l - 2 * d.MARGE, 6, 1))); print("audio_y=" .. y)
  print("midi_x=" .. arrondi(d.case_centre(d.MARGE, l - 2 * d.MARGE, 6, 2))); print("midi_y=" .. y)
  -- Rangée principale : bandeau à gauche, claviers à droite. À l'intérieur
  -- d'un groupe, le premier widget commence après la bordure, la marge
  -- interne et l'espacement de la première rangée (groupe_contenu).
  local principale_y = d.MARGE + d.ESPACE + p.haut * (p.entete + d.ESPACE)
  local contenu_y = d.groupe_contenu(principale_y)
  -- Bandeau : étiquette, curseur, valeur en % ; les curseurs côte à côte.
  local bande_contenu_x = d.MARGE + d.CADRE_GROUPE / 2
  local bande_largeur = p.bande - d.CADRE_GROUPE
  local curseur_y = contenu_y + p.etiquette_curseur + d.ESPACE + p.bande_curseur / 2
  print("general_y=" .. arrondi(curseur_y))
  for c = 0, nb - 1 do
    print("general_" .. c .. "_x=" .. arrondi(d.case_centre(bande_contenu_x, bande_largeur, nb, c)))
  end
  print("general_h=" .. arrondi(p.bande_curseur))
  print("bandeau_x=" .. arrondi(d.MARGE + p.bande / 2))
  -- Bouton de remise à zéro des volumes : rangée pleine largeur sous la
  -- valeur des curseurs (étiquette, curseur, valeur, bouton).
  local reset_y = contenu_y + 2 * p.etiquette_curseur + p.bande_curseur +
    3 * d.ESPACE + p.bouton_reset / 2
  print("reset_x=" .. arrondi(bande_contenu_x + bande_largeur / 2))
  print("reset_y=" .. arrondi(reset_y))
  print("reset_h=" .. arrondi(p.bouton_reset))
  -- Un clavier : COL (0 à ndiv-1). En-tête (nom et Annuler), bloc de jeux
  -- avec le curseur de gain à droite, puis accouplements ou transposition.
  local col = tonumber(os.getenv("COL") or "0")
  local cellw = p.l_jeux / ndiv
  local gx = d.MARGE + p.bande + d.ESPACE + col * (cellw + d.ESPACE)
  local cx = gx + d.CADRE_GROUPE / 2
  local bloc_y = contenu_y + p.entete + d.ESPACE
  local bloc = p.rangs * p.jeu + (p.rangs - 1) * d.ESPACE
  local ligne_gain = math.min(p.etiquette_curseur, math.max(0, bloc / 5))
  local gain_course = bloc - 2 * ligne_gain
  print("gain_x=" .. arrondi(cx + p.largeur_colonne - p.curseur_largeur + p.curseur_largeur / 2))
  print("gain_y=" .. arrondi(bloc_y + ligne_gain + gain_course / 2))
  print("gain_h=" .. arrondi(gain_course))
  -- Transposition : une seule rangée (celle des accouplements) en bas de la
  -- colonne. Quatre cellules de poids {2, 1, 1.2, 1} : le libellé, « − », la
  -- valeur signée, « + » ; le bouton Piano, quand il est là, occupe une
  -- cinquième cellule à poids {1.9, 0.7, 0.9, 0.7, 1.25}.
  local yr = arrondi(bloc_y + bloc + d.ESPACE + p.jeu / 2)
  local poids = piano and {1.9, 0.7, 0.9, 0.7, 1.25} or {2, 1, 1.2, 1}
  print("trans_moins_x=" .. arrondi(d.colonne_ratio(cx, p.largeur_colonne, poids, 2).centre))
  print("trans_valeur_x=" .. arrondi(d.colonne_ratio(cx, p.largeur_colonne, poids, 3).centre))
  print("trans_plus_x=" .. arrondi(d.colonne_ratio(cx, p.largeur_colonne, poids, 4).centre))
  print("trans_y=" .. yr)
  -- Bouton Piano : dernier de la rangée basse. Rangée des accouplements
  -- (nliens + 1 cases égales) ou rangée de transposition (5 cases à poids).
  if nliens > 0 then
    print("piano_x=" .. arrondi(d.case_centre(cx, p.largeur_colonne, nliens + 1, nliens)))
  else
    print("piano_x=" .. arrondi(d.colonne_ratio(cx, p.largeur_colonne, poids, #poids).centre))
  end
  print("piano_y=" .. yr)
elseif mode == "qualite" then
  local rows = tonumber(os.getenv("ROWS")); local cols = tonumber(os.getenv("COLS"))
  local p = d.disposer_qualite(rows, l, h, cols)
  local function y(k) return arrondi(ligne_y(k, p.ligne)) end
  -- Rangée Période : libellé puis sept valeurs, soit 8 colonnes. 768 est la
  -- quatrième valeur, 512 la troisième.
  local per = tonumber(os.getenv("PERIODE_ROW") or "5")
  print("periode_512_x=" .. arrondi(colonne(8, 3))); print("periode_512_y=" .. y(per))
  print("periode_768_x=" .. arrondi(colonne(8, 4))); print("periode_768_y=" .. y(per))
  local xr = colonne(3, 0)
  print("retour_x=" .. arrondi(xr)); print("retour_y=" .. y(0))
  local xt = colonne(6, 2)
  print("temp_x=" .. arrondi(xt)); print("temp_y=" .. y(9))
  local xt3 = colonne(6, 4)
  print("temp3_x=" .. arrondi(xt3)); print("temp3_y=" .. y(9))
  local xrv, w = colonne(2, 1)
  local frac = tonumber(os.getenv("REVERB_FRAC") or "0.25")
  print("reverb_x=" .. arrondi(MARGE + 1 * (w + ESPACE) + w * frac))
  print("reverb_y=" .. y(4))
  print("page_x=" .. arrondi(colonne(3, 1)))
elseif mode == "midi" then
  local ndiv = tonumber(os.getenv("NDIV")); local nassoc = tonumber(os.getenv("NASSOC"))
  local e = {divisions = {}}; for i = 1, ndiv do e.divisions[i] = {} end
  local cfg = {associations = {}}; for i = 1, nassoc do cfg.associations[i] = {} end
  local p = d.disposer_midi(e, cfg, l, h)
  local y = arrondi(ligne_y(0, p.ligne))
  print("retour_x=" .. arrondi(colonne(4, 0))); print("retour_y=" .. y)
  print("connexions_x=" .. arrondi(colonne(4, 1))); print("connexions_y=" .. y)
elseif mode == "connexions" then
  local n = tonumber(os.getenv("NPORTS"))
  local p = d.disposer_connexions(n, l, h)
  local y = arrondi(ligne_y(0, p.ligne))
  print("retour_x=" .. arrondi(colonne(4, 0))); print("retour_y=" .. y)
end
LUA
}

# --- Prérequis -------------------------------------------------------------
PRET=1
[ -x "$BIN" ] || { ignore "e2e (web/build/organum.com absent ; lancer web/scripts/build.sh)"; PRET=0; }
command -v node >/dev/null 2>&1 || { ignore "e2e web (node absent)"; PRET=0; }
command -v chromium >/dev/null 2>&1 || { ignore "e2e web (chromium absent)"; PRET=0; }
command -v Xvfb >/dev/null 2>&1 || { ignore "e2e natif (Xvfb absent)"; PRET=0; }
command -v xdotool >/dev/null 2>&1 || { ignore "e2e natif (xdotool absent)"; PRET=0; }
command -v import >/dev/null 2>&1 || { ignore "e2e natif (ImageMagick import absent)"; PRET=0; }
command -v redbean >/dev/null 2>&1 || { ignore "e2e natif (redbean absent)"; PRET=0; }

if [ "$PRET" -eq 0 ]; then
  echo
  echo "== 0 OK, $ECHECS échec(s), $IGNORES ignoré(s)"
  exit 0
fi

# Sur NixOS, libasound n'est pas dans un chemin standard : prendre la plus
# ancienne trouvée dans le magasin, comme web/scripts/test-qualite.sh.
if [ -z "${ORGANUM_LIBASOUND:-}" ] && [ -d /nix/store ]; then
  CANDIDAT=$(ls /nix/store/*-alsa-lib-*/lib/libasound.so.2 2>/dev/null | sort -V | head -n 1)
  if [ -n "$CANDIDAT" ]; then
    ORGANUM_LIBASOUND="$CANDIDAT"
    export ORGANUM_LIBASOUND
  fi
fi

creer_faux_wpctl
ecrire_helper_lua || { echo "ÉCHEC : compilation de fenetre_disposition" >&2; exit 1; }

# Adresse non locale pour l'e2e de l'authentification (jamais orgue.lan).
HOTE_AUTH=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n 1)

# --- Interface web ---------------------------------------------------------
DEBUT_WEB=$(date +%s%N)
if demarrer_organum non && demarrer_chromium; then
  CDP_PORT="$CDP_PORT" BASE_URL="$URL" MODE=full \
    node "$RACINE/scripts/e2e-web.mjs" >"$TMP/web.log" 2>&1
  CODE_WEB=$?
  sed 's/^/        /' "$TMP/web.log"
  if [ "$CODE_WEB" -eq 0 ]; then
    OKS=$((OKS + 1))
  else
    ECHECS=$((ECHECS + 1))
  fi
else
  echec "e2e web : serveur ou Chromium ne démarre pas"
fi
arreter_chromium
arreter_organum
FIN_WEB=$(date +%s%N)
echo "      durée web : $(duree "$DEBUT_WEB" "$FIN_WEB")"

# --- Authentification web (Chromium headless, adresse non locale) ----------
DEBUT_AUTH=$(date +%s%N)
if [ -z "$HOTE_AUTH" ]; then
  ignore "e2e authentification web (aucune adresse IPv4 non locale)"
elif demarrer_organum_auth && demarrer_chromium; then
  CDP_PORT="$CDP_PORT" BASE_URL="$URL" ORGANUM_USER=organiste \
    ORGANUM_PASS=secret01 \
    node "$RACINE/scripts/e2e-auth.mjs" >"$TMP/web-auth.log" 2>&1
  CODE_AUTH=$?
  sed 's/^/        /' "$TMP/web-auth.log"
  if [ "$CODE_AUTH" -eq 0 ]; then
    OKS=$((OKS + 1))
  else
    ECHECS=$((ECHECS + 1))
  fi
else
  echec "e2e authentification web : serveur ou Chromium ne démarre pas"
fi
arreter_chromium
arreter_organum
FIN_AUTH=$(date +%s%N)
echo "      durée authentification web : $(duree "$DEBUT_AUTH" "$FIN_AUTH")"

# --- Interface native ------------------------------------------------------
DEBUT_NATIF=$(date +%s%N)
if demarrer_xvfb && demarrer_organum oui && attendre_fenetre; then
  chemin_capture_lu=0
  # Paramètres réels de la console : nombre de claviers, de jeux et
  # d'accouplements, et présence du piano échantillonné (SoundFont chargé).
  # La fenêtre reçoit alors deux curseurs généraux (Volume par le faux wpctl,
  # Pédale) plus Piano : les coordonnées cliquables doivent compter les trois.
  read -r NDIV MAXJEUX LIENS PIANO <<<"$(parametres_transposition)"
  NGENERAUX=$((2 + PIANO))
  for taille in "800 480" "1024 640" "1920 1080"; do
    set -- $taille
    largeur=$1
    hauteur=$2
    redimensionner "$largeur" "$hauteur"

    read -r R1 R2 <<<"$(parametres_console)"
    eval "$(GENERAUX=$NGENERAUX coords console "$largeur" "$hauteur" "$R1" "$R2")"

    capturer "console-$largeur-$hauteur"
    H_CONSOLE=$(md5sum "$CAPTURES/console-$largeur-$hauteur.png" | cut -d' ' -f1)

    clic_xy "$audio_x" "$audio_y"
    capturer "audio-$largeur-$hauteur"
    H_AUDIO=$(md5sum "$CAPTURES/audio-$largeur-$hauteur.png" | cut -d' ' -f1)
    if [ "$H_CONSOLE" = "$H_AUDIO" ]; then
      echec "natif $largeur×$hauteur : le clic Audio ne change pas l'écran"
    else
      ok "natif $largeur×$hauteur : panneau Audio ouvert par clic"
    fi

    read -r QROWS QCOLS QPER <<<"$(parametres_qualite)"
    eval "$(coords qualite "$largeur" "$hauteur" "$QROWS" "$QCOLS" 0.25 "$QPER")"
    clic_xy "$retour_x" "$retour_y"
    capturer "console-retour-$largeur-$hauteur"

    clic_xy "$midi_x" "$midi_y"
    capturer "midi-$largeur-$hauteur"
    H_MIDI=$(md5sum "$CAPTURES/midi-$largeur-$hauteur.png" | cut -d' ' -f1)
    if [ "$H_MIDI" = "$H_CONSOLE" ]; then
      echec "natif $largeur×$hauteur : le clic MIDI ne change pas l'écran"
    else
      ok "natif $largeur×$hauteur : panneau MIDI ouvert par clic"
    fi

    read -r NDIV NASSOC <<<"$(parametres_midi)"
    eval "$(coords midi "$largeur" "$hauteur" "$NDIV" "$NASSOC")"
    clic_xy "$connexions_x" "$connexions_y"
    capturer "connexions-$largeur-$hauteur"
    H_CONN=$(md5sum "$CAPTURES/connexions-$largeur-$hauteur.png" | cut -d' ' -f1)
    if [ "$H_CONN" = "$H_MIDI" ]; then
      echec "natif $largeur×$hauteur : le clic Connexions ne change pas l'écran"
    else
      ok "natif $largeur×$hauteur : panneau Connexions ouvert par clic"
    fi

    NPORTS=$(parametres_connexions)
    eval "$(coords connexions "$largeur" "$hauteur" "$NPORTS")"
    clic_xy "$retour_x" "$retour_y"
    eval "$(coords midi "$largeur" "$hauteur" "$NDIV" "$NASSOC")"
    clic_xy "$retour_x" "$retour_y"
  done

  redimensionner 1024 640
  stable_etat "natif console"

  # Commandes réelles à 1920×1080, où les cibles sont les plus grandes.
  redimensionner 1920 1080
  read -r R1 R2 <<<"$(parametres_console)"
  eval "$(GENERAUX=$NGENERAUX coords console 1920 1080 "$R1" "$R2")"

  # Bandeau des curseurs généraux : « Volume » (système, faux wpctl) et
  # « Pédale » (volume du moteur) côte à côte et verticaux. Saisie relative :
  # un appui seul ne change rien, un glissement de 20 % baisse la valeur.
  eval "$(NDIV=$NDIV MAXJEUX=$MAXJEUX LIENS=$LIENS COL=0 GENERAUX=$NGENERAUX coords console 1920 1080 "$R1" "$R2")"
  ecrire_json_api '{"volume":0.5}'
  attendre_valeur 'e["volume"]' 0.5 0.01 50
  VOL_AVANT=$(lire_api | python3 -c 'import json,sys; print(json.load(sys.stdin)["volume"])' 2>/dev/null || echo 0.5)
  clic_xy "$general_1_x" "$general_y"
  sleep 0.3
  VOL_APRES_CLIC=$(lire_api | python3 -c 'import json,sys; print(json.load(sys.stdin)["volume"])' 2>/dev/null || echo 0.5)
  if python3 - "$VOL_AVANT" "$VOL_APRES_CLIC" <<'PY'
import sys
sys.exit(0 if abs(float(sys.argv[1]) - float(sys.argv[2])) < 0.02 else 1)
PY
  then
    ok "natif : un appui dans la colonne du curseur ne change pas la valeur"
  else
    echec "natif : l'appui dans la colonne a fait sauter la valeur ($VOL_AVANT → $VOL_APRES_CLIC)"
  fi
  # Glissement vers le bas de 20 % de la course : la valeur diminue d'autant.
  eval "$(python3 - "$general_1_x" "$general_y" "$general_h" <<'PY'
import sys
x, y, h = float(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3])
course = h - 24
print("glisse_depart_y=%d glisse_arrivee_y=%d" % (round(y), round(y + 0.2 * course)))
PY
)"
  glisser_xy "$general_1_x" "$glisse_depart_y" "$general_1_x" "$glisse_arrivee_y"
  if attendre_valeur 'e["volume"]' 0.3 0.05 60; then
    ok "natif : glissement du curseur de pédale, valeur relue dans /api/orgue"
  else
    echec "natif : le glissement du curseur de pédale ne donne pas ~0,3 ($(lire_api | head -c 200))"
  fi
  ecrire_json_api '{"volume":0.5}'
  attendre_valeur 'e["volume"]' 0.5 0.01 50

  # Molette : un cran = ±1 % (haut = plus fort), sur la colonne du curseur.
  xdotool mousemove --window "$WID" "$general_1_x" "$general_y"
  sleep 0.2
  xdotool click 4
  sleep 0.4
  if attendre_valeur 'e["volume"]' 0.51 0.01 40; then
    ok "natif : molette d'un cran sur la pédale (+1 %)"
  else
    echec "natif : la molette n'a pas augmenté la pédale de 1 % ($(lire_api | head -c 120))"
  fi
  xdotool click 5
  sleep 0.4
  if attendre_valeur 'e["volume"]' 0.5 0.01 40; then
    ok "natif : molette d'un cran vers le bas (−1 %)"
  else
    echec "natif : la molette n'a pas baissé la pédale de 1 % ($(lire_api | head -c 120))"
  fi

  ecrire_json_api '{"gain":{"division":0,"value":0.5}}'
  attendre_valeur 'e["divisions"][0]["gain"]' 0.5 0.01 50
  eval "$(NDIV=$NDIV MAXJEUX=$MAXJEUX LIENS=$LIENS COL=0 GENERAUX=$NGENERAUX coords console 1920 1080 "$R1" "$R2")"
  eval "$(python3 - "$gain_x" "$gain_y" "$gain_h" <<'PY'
import sys
x, y, h = float(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3])
course = h - 24
print("gain_depart_y=%d gain_arrivee_y=%d" % (round(y), round(y + 0.2 * course)))
PY
)"
  glisser_xy "$gain_x" "$gain_depart_y" "$gain_x" "$gain_arrivee_y"
  if attendre_valeur 'e["divisions"][0]["gain"]' 0.3 0.05 60; then
    ok "natif : glissement du curseur de gain d'un clavier, valeur relue dans /api/orgue"
  else
    echec "natif : le glissement du curseur de gain ne donne pas ~0,3 ($(lire_api | head -c 200))"
  fi
  ecrire_json_api '{"gain":{"division":0,"value":0.5}}'
  attendre_valeur 'e["divisions"][0]["gain"]' 0.5 0.01 50

  # Transposition : clic réel sur « + » dans la colonne du Manuel III, valeur
  # relue par l'API, accent visible (captures), borne haute inactive.
  eval "$(NDIV=$NDIV MAXJEUX=$MAXJEUX LIENS=$LIENS COL=0 PIANO=$PIANO NLIENS=0 GENERAUX=$NGENERAUX coords console 1920 1080 "$R1" "$R2")"
  ecrire_json_api '{"transposition":0}'
  attendre_api '"transposition":0' 50
  capturer "trans-avant"
  H_TRANS_AVANT=$(md5sum "$CAPTURES/trans-avant.png" | cut -d' ' -f1)
  clic_xy "$trans_plus_x" "$trans_y"
  if attendre_api '"transposition":1' 50; then
    ok "natif : transposition +1 par clic et relue dans /api/orgue"
  else
    echec "natif : le clic sur + n'a pas transposé de +1"
  fi
  capturer "trans-apres"
  H_TRANS_APRES=$(md5sum "$CAPTURES/trans-apres.png" | cut -d' ' -f1)
  if [ "$H_TRANS_AVANT" = "$H_TRANS_APRES" ]; then
    echec "natif : la valeur non nulle ne change pas l'affichage (mise en évidence absente)"
  else
    ok "natif : valeur non nulle mise en évidence (capture changée)"
  fi
  # Depuis +1, un clic sur la valeur centrale remet la transposition à 0.
  clic_xy "$trans_valeur_x" "$trans_y"
  if attendre_api '"transposition":0' 50; then
    ok "natif : clic sur la valeur remet la transposition à 0"
  else
    echec "natif : le clic sur la valeur n'a pas remis la transposition à 0"
  fi
  ecrire_json_api '{"transposition":12}'
  attendre_api '"transposition":12' 50
  clic_xy "$trans_plus_x" "$trans_y"
  sleep 0.4
  if lire_api | grep -qF '"transposition":12'; then
    ok "natif : + inactif à la borne +12"
  else
    echec "natif : + actif au-delà de la borne +12"
  fi
  ecrire_json_api '{"transposition":0}'
  attendre_api '"transposition":0' 50

  # Piano échantillonné : bouton de chaque clavier (dernier de la rangée
  # basse) et curseur du bandeau. Les cibles viennent de fenetre_disposition
  # par le même calcul que la fenêtre ; l'état est relu dans /api/orgue.
  DERNIERE=$((NDIV - 1))
  if [ "$PIANO" = 1 ]; then
    # 1. Dernier clavier (le pédalier) : ses accouplements puis Piano,
    # dernière case de la rangée.
    ecrire_json_api "{\"piano\":{\"division\":$DERNIERE,\"actif\":false}}"
    if ! attendre_valeur "e[\"divisions\"][$DERNIERE][\"piano\"]" 0 0 50; then
      echec "natif : le piano du pédalier ne se remet pas à l'arrêt"
    fi
    NL_PEDALE=$(liens_division "$DERNIERE")
    eval "$(NDIV=$NDIV MAXJEUX=$MAXJEUX LIENS=$LIENS PIANO=1 NLIENS=$NL_PEDALE COL=$DERNIERE GENERAUX=$NGENERAUX coords console 1920 1080 "$R1" "$R2")"
    capturer "piano-avant"
    H_PIANO_AVANT=$(md5sum "$CAPTURES/piano-avant.png" | cut -d' ' -f1)
    clic_xy "$piano_x" "$piano_y"
    if attendre_valeur "e[\"divisions\"][$DERNIERE][\"piano\"]" 1 0 50; then
      ok "natif : bouton Piano du pédalier, état relu dans divisions[$DERNIERE].piano"
    else
      echec "natif : le clic sur Piano (pédalier) ne change pas divisions[$DERNIERE].piano"
    fi
    capturer "piano-apres"
    H_PIANO_APRES=$(md5sum "$CAPTURES/piano-apres.png" | cut -d' ' -f1)
    if [ "$H_PIANO_AVANT" = "$H_PIANO_APRES" ]; then
      echec "natif : le bouton Piano enfoncé ne change pas l'affichage"
    else
      ok "natif : bouton Piano enfoncé visible (capture changée)"
    fi
    clic_xy "$piano_x" "$piano_y"
    if attendre_valeur "e[\"divisions\"][$DERNIERE][\"piano\"]" 0 0 50; then
      ok "natif : second clic sur Piano relâche la division"
    else
      echec "natif : le second clic sur Piano ne relâche pas la division"
    fi

    # 2. Manuel III : Piano partage sa rangée avec la Transposition, qui ne
    # doit pas bouger.
    ecrire_json_api '{"transposition":0}'
    attendre_api '"transposition":0' 50
    ecrire_json_api '{"piano":{"division":0,"actif":false}}'
    attendre_valeur 'e["divisions"][0]["piano"]' 0 0 50
    eval "$(NDIV=$NDIV MAXJEUX=$MAXJEUX LIENS=$LIENS PIANO=1 NLIENS=0 COL=0 GENERAUX=$NGENERAUX coords console 1920 1080 "$R1" "$R2")"
    clic_xy "$piano_x" "$piano_y"
    if attendre_valeur 'e["divisions"][0]["piano"]' 1 0 50; then
      ok "natif : bouton Piano du clavier à transposition, état relu"
    else
      echec "natif : le clic sur Piano (Manuel III) ne change pas divisions[0].piano"
    fi
    if lire_api | grep -qF '"transposition":0'; then
      ok "natif : la transposition reste à 0 après le clic sur Piano"
    else
      echec "natif : le clic sur Piano a modifié la transposition"
    fi
    ecrire_json_api '{"piano":{"division":0,"actif":false}}'
    attendre_valeur 'e["divisions"][0]["piano"]' 0 0 50

    # 3. Curseur Piano du bandeau : troisième colonne, après « Pédale ».
    ecrire_json_api '{"piano_volume":0.5}'
    attendre_valeur 'e["piano_volume"]' 0.5 0.01 50
    eval "$(NDIV=$NDIV MAXJEUX=$MAXJEUX LIENS=$LIENS COL=0 GENERAUX=$NGENERAUX coords console 1920 1080 "$R1" "$R2")"
    eval "$(python3 - "$general_2_x" "$general_y" "$general_h" <<'PY'
import sys
x, y, h = float(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3])
course = h - 24
print("piano_depart_y=%d piano_arrivee_y=%d" % (round(y), round(y + 0.2 * course)))
PY
)"
    glisser_xy "$general_2_x" "$piano_depart_y" "$general_2_x" "$piano_arrivee_y"
    if attendre_valeur 'e["piano_volume"]' 0.3 0.05 60; then
      ok "natif : glissement du curseur Piano, piano_volume relu dans /api/orgue"
    else
      echec "natif : le glissement du curseur Piano ne donne pas ~0,3 ($(lire_api | head -c 200))"
    fi
    xdotool mousemove --window "$WID" "$general_2_x" "$general_y"
    sleep 0.2
    xdotool click 4
    sleep 0.4
    if attendre_valeur 'e["piano_volume"]' 0.31 0.01 40; then
      ok "natif : molette d'un cran sur le curseur Piano (+1 %)"
    else
      echec "natif : la molette n'a pas augmenté le piano de 1 % ($(lire_api | head -c 120))"
    fi
    ecrire_json_api '{"piano_volume":0.5}'
    attendre_valeur 'e["piano_volume"]' 0.5 0.01 50
  else
    ignore "natif : piano indisponible (SoundFont non chargé), contrôles Piano sautés"
  fi

  # Remise à zéro des volumes : deux gains et le piano déréglés, Volume
  # système et Pédale à des valeurs non par défaut. Un clic réel sur le
  # bouton ↺ du bandeau (icône dessinée, sous les curseurs) doit remettre
  # gains et piano aux défauts publiés par le moteur, sans toucher aux deux
  # autres réglages.
  eval "$(NDIV=$NDIV MAXJEUX=$MAXJEUX LIENS=$LIENS COL=0 PIANO=$PIANO NLIENS=0 GENERAUX=$NGENERAUX coords console 1920 1080 "$R1" "$R2")"
  DEFAUT_GAIN=$(lire_api | python3 -c 'import json,sys; print(json.load(sys.stdin).get("gain_defaut"))')
  DEFAUT_PIANO=$(lire_api | python3 -c 'import json,sys; print(json.load(sys.stdin).get("piano_volume_defaut"))')
  ecrire_json_api '{"gain":{"division":0,"value":0.3}}'
  attendre_valeur 'e["divisions"][0]["gain"]' 0.3 0.02 50
  ecrire_json_api "{\"gain\":{\"division\":$DERNIERE,\"value\":0.7}}"
  attendre_valeur "e[\"divisions\"][$DERNIERE][\"gain\"]" 0.7 0.02 50
  ecrire_json_api '{"volume":0.7}'
  attendre_valeur 'e["volume"]' 0.7 0.02 50
  if [ "$PIANO" = 1 ]; then
    ecrire_json_api '{"piano_volume":0.3}'
    attendre_valeur 'e["piano_volume"]' 0.3 0.02 50
  fi
  curl -s -X POST -H 'Content-Type: application/json' \
    -d '{"volume":70,"muted":false}' "$URL/api/volume" >/dev/null
  for _ in $(seq 1 30); do
    VS=$(curl -s "$URL/api/volume" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("volume"))' 2>/dev/null)
    [ "${VS%.*}" = 70 ] && break
    sleep 0.1
  done
  capturer "reset-avant"
  H_RESET_AVANT=$(md5sum "$CAPTURES/reset-avant.png" | cut -d' ' -f1)
  clic_xy "$reset_x" "$reset_y"
  if attendre_valeur 'e["divisions"][0]["gain"]' "$DEFAUT_GAIN" 0.02 60 &&
     attendre_valeur "e[\"divisions\"][$DERNIERE][\"gain\"]" "$DEFAUT_GAIN" 0.02 60; then
    ok "natif : clic sur la remise à zéro, deux gains aux défauts"
  else
    echec "natif : la remise à zéro ne ramène pas les gains aux défauts ($(lire_api | head -c 240))"
  fi
  if [ "$PIANO" = 1 ]; then
    if attendre_valeur 'e["piano_volume"]' "$DEFAUT_PIANO" 0.02 60; then
      ok "natif : volume du piano remis au défaut par le même clic"
    else
      echec "natif : le volume du piano n'est pas revenu au défaut"
    fi
  fi
  if attendre_valeur 'e["volume"]' 0.7 0.02 30; then
    ok "natif : Pédale inchangée par la remise à zéro"
  else
    echec "natif : la remise à zéro a modifié la Pédale ($(lire_api | head -c 160))"
  fi
  VS=$(curl -s "$URL/api/volume" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("volume"))' 2>/dev/null)
  if [ "${VS%.*}" = 70 ]; then
    ok "natif : Volume système inchangé par la remise à zéro"
  else
    echec "natif : la remise à zéro a modifié le Volume système ($VS)"
  fi
  capturer "reset-apres"
  H_RESET_APRES=$(md5sum "$CAPTURES/reset-apres.png" | cut -d' ' -f1)
  if [ "$H_RESET_AVANT" = "$H_RESET_APRES" ]; then
    echec "natif : les curseurs ne changent pas à l'affichage après la remise à zéro"
  else
    ok "natif : curseurs affichés à jour après la remise à zéro (capture changée)"
  fi
  # Remise en ordre pour la suite.
  curl -s -X POST -H 'Content-Type: application/json' \
    -d '{"volume":50,"muted":false}' "$URL/api/volume" >/dev/null
  ecrire_json_api '{"volume":0.5}'
  attendre_valeur 'e["volume"]' 0.5 0.02 50

  clic_xy "$audio_x" "$audio_y"
  read -r QROWS QCOLS QPER <<<"$(parametres_qualite)"
  eval "$(coords qualite 1920 1080 "$QROWS" "$QCOLS" 0.25 "$QPER")"

  ecrire_json_api '{"temperament":5}'
  attendre_api '"temperament":5' 100
  clic_xy "$temp_x" "$temp_y"
  if attendre_api '"temperament":1' 150; then
    ok "natif : tempérament 1 choisi par clic et relu dans /api/orgue"
  else
    echec "natif : le clic sur le tempérament n'a pas appliqué la valeur 1"
  fi
  sleep 1
  if [ "$(lire_api | python3 -c 'import json,sys; print(json.load(sys.stdin)["temperament"])' 2>/dev/null)" = 1 ]; then
    ok "natif : tempérament stable après le clic (une seule commande)"
  else
    echec "natif : le tempérament a changé à nouveau sans clic"
  fi

  # Rafale réelle : le calcul est assez long pour que la deuxième cible
  # arrive avant la fin de la première. La capture prise juste après les
  # deux clics doit montrer l'état « en cours » (libellé et bouton changés),
  # et la dernière demande doit finalement l'emporter.
  ecrire_json_api '{"temperament":5}'
  attendre_api '"temperament":5' 100
  sleep 1
  capturer "temp-avant"
  H_TEMP_AVANT=$(md5sum "$CAPTURES/temp-avant.png" | cut -d' ' -f1)
  clic_xy "$temp_x" "$temp_y"
  clic_xy "$temp3_x" "$temp3_y"
  capturer "temp-en-cours"
  H_TEMP_ENC=$(md5sum "$CAPTURES/temp-en-cours.png" | cut -d' ' -f1)
  if [ "$H_TEMP_AVANT" = "$H_TEMP_ENC" ]; then
    echec "natif : l'état « en cours » du tempérament n'apparaît pas après les deux clics"
  else
    ok "natif : état « en cours » visible pendant le calcul du tempérament"
  fi
  if attendre_api '"temperament":3' 250; then
    ok "natif : la dernière demande de la rafale (tempérament 3) l'emporte"
  else
    echec "natif : la dernière demande de la rafale n'a pas été appliquée"
  fi
  sleep 1
  if [ "$(lire_api | python3 -c 'import json,sys; print(json.load(sys.stdin)["temperament"])' 2>/dev/null)" = 3 ]; then
    ok "natif : tempérament 3 stable après la rafale, sans nouvelle commande"
  else
    echec "natif : le tempérament change encore après la rafale"
  fi

  REVERB_AVANT=$(lire_api | python3 -c 'import json,sys; print(json.load(sys.stdin)["reverb"])' 2>/dev/null || echo 0)
  REVERB_FRAC=$(python3 - "$REVERB_AVANT" <<'PY'
import sys
v = float(sys.argv[1])
print("0.75" if v < 0.5 else "0.25")
PY
)
  eval "$(coords qualite 1920 1080 "$QROWS" "$QCOLS" "$REVERB_AVANT" "$QPER")"
  REVERB_X_AVANT=$reverb_x
  eval "$(coords qualite 1920 1080 "$QROWS" "$QCOLS" "$REVERB_FRAC" "$QPER")"
  glisser_xy "$REVERB_X_AVANT" "$reverb_y" "$reverb_x" "$reverb_y"
  # Le clic part vers la fenêtre native, qui envoie son POST de façon
  # asynchrone : attendre que la valeur CHANGE (échéance 3 s) au lieu de
  # lire un unique instantané 0,5 s après le relâchement.
  REVERB_APRES=$REVERB_AVANT
  i=0
  while [ "$i" -lt 30 ]; do
    REVERB_APRES=$(lire_api | python3 -c 'import json,sys; print(json.load(sys.stdin)["reverb"])' 2>/dev/null || echo 0)
    if python3 - "$REVERB_AVANT" "$REVERB_APRES" <<'PY'
import sys
sys.exit(0 if abs(float(sys.argv[1]) - float(sys.argv[2])) > 0.05 else 1)
PY
    then
      break
    fi
    sleep 0.1
    i=$((i + 1))
  done
  if python3 - "$REVERB_AVANT" "$REVERB_APRES" <<'PY'
import sys
a, b = float(sys.argv[1]), float(sys.argv[2])
sys.exit(0 if abs(a - b) > 0.05 else 1)
PY
  then
    ok "natif : réverbération modifiée par clic et relue dans /api/orgue ($REVERB_AVANT → $REVERB_APRES, $((i * 100)) ms)"
  else
    echec "natif : le clic sur le curseur de réverbération ne change pas la valeur ($REVERB_AVANT → $REVERB_APRES, inchangée après $((i * 100)) ms)"
  fi

  clic_xy "$retour_x" "$retour_y"
  read -r R1 R2 <<<"$(parametres_console)"
  eval "$(GENERAUX=$NGENERAUX coords console 1920 1080 "$R1" "$R2")"
  ecrire_json_api '{"stop":{"division":0,"index":0,"on":true}}'
  attendre_api '"on":true' 50
  sleep 0.3
  lire_api >"$TMP/panique-avant.json"
  clic_xy "$panique_x" "$panique_y"
  sleep 0.4
  lire_api >"$TMP/panique-apres.json"
  if python3 - "$TMP/panique-avant.json" "$TMP/panique-apres.json" <<'PY'
import json, sys
a = json.load(open(sys.argv[1]))
b = json.load(open(sys.argv[2]))
def jeux(e):
    return [bool(j.get("on")) for d in e.get("divisions", []) for j in d.get("stops", [])]
sys.exit(0 if jeux(a) == jeux(b) else 1)
PY
  then
    ok "natif : Panique acceptée par un clic (les registres ne changent pas)"
  else
    echec "natif : Panique a modifié les registres"
  fi
  sleep 1
  lire_api >"$TMP/panique-stable.json"
  if python3 - "$TMP/panique-apres.json" "$TMP/panique-stable.json" <<'PY'
import json, sys
a = json.load(open(sys.argv[1]))
b = json.load(open(sys.argv[2]))
def jeux(e):
    return [bool(j.get("on")) for d in e.get("divisions", []) for j in d.get("stops", [])]
sys.exit(0 if jeux(a) == jeux(b) else 1)
PY
  then
    ok "natif : état stable après Panique, sans clic"
  else
    echec "natif : l'état change après Panique sans clic"
  fi

  # --- Interface croisée : web et natif sur le même serveur --------------
  # La cible du tempérament est publiée par le serveur : un clic dans une
  # interface doit se voir dans l'autre, et un POST doit être reflété par
  # les deux. La fenêtre native est déjà ouverte sur ce serveur.
  redimensionner 1920 1080
  read -r R1 R2 <<<"$(parametres_console)"
  eval "$(GENERAUX=$NGENERAUX coords console 1920 1080 "$R1" "$R2")"
  eval "$(NDIV=$NDIV MAXJEUX=$MAXJEUX LIENS=$LIENS COL=0 PIANO=$PIANO NLIENS=0 GENERAUX=$NGENERAUX coords console 1920 1080 "$R1" "$R2")"
  clic_xy "$audio_x" "$audio_y"
  read -r QROWS QCOLS QPER <<<"$(parametres_qualite)"
  eval "$(coords qualite 1920 1080 "$QROWS" "$QCOLS" 0.25 "$QPER")"
  # Période 768 : clic réel sur la quatrième des sept valeurs, relu par l'API.
  clic_xy "$periode_768_x" "$periode_768_y"
  if attendre_api '"periode":768' 200; then
    ok "natif : période 768 choisie par clic et relue dans /api/orgue"
  else
    echec "natif : le clic sur la période 768 n'a pas appliqué la valeur"
  fi
  clic_xy "$periode_512_x" "$periode_512_y"
  if attendre_api '"periode":512' 200; then
    ok "natif : retour à la période 512 par clic"
  else
    echec "natif : le retour à la période 512 par clic a échoué"
  fi
  if demarrer_chromium; then
    WID="$WID" DISPLAY="$DISPLAY" CAPTURES="$CAPTURES" \
    TEMP1_X="$temp_x" TEMP1_Y="$temp_y" TEMP3_X="$temp3_x" TEMP3_Y="$temp3_y" \
    RETOUR_X="$retour_x" RETOUR_Y="$retour_y" \
    TRANS_PLUS_X="$trans_plus_x" TRANS_PLUS_Y="$trans_y" \
    CDP_PORT="$CDP_PORT" BASE_URL="$URL" MODE=croise \
      node "$RACINE/scripts/e2e-web.mjs" >"$TMP/croise.log" 2>&1
    CODE_CROISE=$?
    sed 's/^/        /' "$TMP/croise.log"
    if [ "$CODE_CROISE" -eq 0 ]; then
      OKS=$((OKS + 1))
    else
      ECHECS=$((ECHECS + 1))
    fi
  else
    echec "e2e croisé : Chromium ne démarre pas"
  fi
  arreter_chromium
else
  echec "e2e natif : Xvfb, organum ou fenêtre indisponible"
fi
arreter_organum
arreter_xvfb
FIN_NATIF=$(date +%s%N)
echo "      durée natif : $(duree "$DEBUT_NATIF" "$FIN_NATIF")"

# --- Mutation : --fill absent et « nouveau » local -------------------------
# Les deux régressions corrigées par d84f92c (--fill) et a498232 (nouveau)
# sont réintroduites temporairement ; le test doit les détecter. Les sources
# sont restaurées et l'archive reconstruite avant de continuer.
DEBUT_MUT=$(date +%s%N)
cp "$RACINE/web/src/page_audio.moon" "$TMP/page_audio.moon.orig"
cp "$RACINE/web/src/fenetre.moon" "$TMP/fenetre.moon.orig"
MUTATION_ACTIVE=1
python3 - "$RACINE/web/src/page_audio.moon" "$RACINE/web/src/fenetre.moon" <<'PY'
import sys

chemin_audio, chemin_fenetre = sys.argv[1], sys.argv[2]

audio = open(chemin_audio, encoding='utf-8').read()
ligne = "    el.style.setProperty('--fill', pourcent + '%');\n"
if ligne not in audio:
    raise SystemExit("mutation : ligne --fill introuvable")
open(chemin_audio, 'w', encoding='utf-8').write(audio.replace(ligne, "    /* mutation : --fill absent */\n", 1))

fenetre = open(chemin_fenetre, encoding='utf-8').read()
avant = """            nouveau = if ui\\largeur_texte(nom) <= p.case - 4
              ui\\choix nom, jeu.actif
            else
              coupe = decoupe ui, nom
              if coupe and coupe.large <= p.case - 2
                ui\\choix_deux coupe.a, coupe.b, jeu.actif
              else
                ui\\choix nom, jeu.actif
"""
apres = """            if ui\\largeur_texte(nom) <= p.case - 4
              nouveau = ui\\choix nom, jeu.actif
            else
              coupe = decoupe ui, nom
              if coupe and coupe.large <= p.case - 2
                nouveau = ui\\choix_deux coupe.a, coupe.b, jeu.actif
              else
                nouveau = ui\\choix nom, jeu.actif
"""
if avant not in fenetre:
    raise SystemExit("mutation : bloc nouveau introuvable")
open(chemin_fenetre, 'w', encoding='utf-8').write(fenetre.replace(avant, apres, 1))
PY
MUTATION_APPLIQUEE=$?

if [ "$MUTATION_APPLIQUEE" -ne 0 ]; then
  echec "mutation : impossible de réintroduire les deux bugs"
  restaurer_mutation
else
  if ORGANUM="$RACINE/externe/cosmopolitan/o//tool/organum/organum" \
       "$RACINE/web/scripts/build.sh" >"$TMP/build-mutation.log" 2>&1; then
    # --fill absent, détecté par le contrôle web ciblé.
    if demarrer_organum non; then
      if demarrer_chromium; then
        CDP_PORT="$CDP_PORT" BASE_URL="$URL" MODE=fill \
          node "$RACINE/scripts/e2e-web.mjs" >"$TMP/mutation-web.log" 2>&1
        CODE_MUT_WEB=$?
        sed 's/^/        /' "$TMP/mutation-web.log"
        if [ "$CODE_MUT_WEB" -eq 0 ]; then
          ok "mutation : le bug --fill absent fait échouer le contrôle e2e"
        else
          echec "mutation : le bug --fill absent n'est pas détecté"
        fi
      else
        echec "mutation web : Chromium ne démarre pas"
        sed 's/^/        /' "$TMP/chromium.log" 2>/dev/null || true
      fi
    else
      echec "mutation web : le serveur ne démarre pas"
    fi
    arreter_chromium
    arreter_organum

    # « nouveau » local, détecté par l'instabilité de la console native.
    if demarrer_xvfb && demarrer_organum oui && attendre_fenetre; then
      redimensionner 1024 640
      lire_api >"$TMP/mut-1.json"
      sleep 2
      lire_api >"$TMP/mut-2.json"
      if python3 - "$TMP/mut-1.json" "$TMP/mut-2.json" <<'PY'
import json, sys
a = json.load(open(sys.argv[1]))
b = json.load(open(sys.argv[2]))
def jeux(e):
    return [bool(j.get("on")) for d in e.get("divisions", []) for j in d.get("stops", [])]
sys.exit(0 if (a.get("seq") != b.get("seq") or jeux(a) != jeux(b)) else 1)
PY
      then
        ok "mutation : le bug « nouveau » local rend la console instable (détecté)"
      else
        echec "mutation : le bug « nouveau » local n'est pas détecté"
      fi
    else
      echec "mutation native : Xvfb, organum ou fenêtre indisponible"
    fi
    arreter_organum
    arreter_xvfb
  else
    echec "mutation : reconstruction de l'interface impossible"
    sed 's/^/        /' "$TMP/build-mutation.log"
  fi

  restaurer_mutation
  if ORGANUM="$RACINE/externe/cosmopolitan/o//tool/organum/organum" \
       "$RACINE/web/scripts/build.sh" >"$TMP/build-restauration.log" 2>&1; then
    ok "mutation : sources restaurées et interface reconstruite"
  else
    echec "mutation : reconstruction après restauration impossible"
    sed 's/^/        /' "$TMP/build-restauration.log"
  fi
  if git -C "$RACINE" diff --quiet -- web/src/page_audio.moon web/src/fenetre.moon; then
    ok "mutation : aucune source modifiée après restauration (git status propre pour ces fichiers)"
  else
    echec "mutation : sources encore modifiées après restauration"
  fi
fi
FIN_MUT=$(date +%s%N)
echo "      durée mutation : $(duree "$DEBUT_MUT" "$FIN_MUT")"

FIN_NS=$(date +%s%N)
echo
echo "== $OKS OK, $ECHECS échec(s), $IGNORES ignoré(s), total $(duree "$DEBUT_NS" "$FIN_NS")"
echo "== captures natives : $CAPTURES"
[ "$ECHECS" -eq 0 ]
