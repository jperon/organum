#!/bin/sh
# Tests de l'API des réglages de qualité (backend Lua/HTTP + persistance).
# Lance web/build/organum.com sur un port libre avec un état temporaire et un
# périphérique ALSA muet (null) : aucun son n'est produit. Le processus lancé
# est arrêté par son PID (jamais pkill -f).
# Sortie : une ligne OK/ÉCHEC par contrôle ; code de retour non nul si échec.
set -u

# Sûreté : sur l'ALSA null, snd_pcm_writei ne bloque pas (le plugin consomme
# le tampon immédiatement, cf. plateforme/linux/audio_alsa.c:729-732) ; la
# boucle audio de cosmo/lorganum.c:978 rend donc aussi vite que possible. Si
# le fil obtenait SCHED_FIFO 70 (cosmo/lorganum.c:881), il affamerait les
# interruptions Wi-Fi de la machine.
# ulimit -r 0 retire ce droit à tout le sous-arbre (script, organum, Xvfb) ;
# chaque lancement vérifie ensuite que le serveur publie temps_reel=false.
ulimit -r 0 2>/dev/null || {
  echo "ÉCHEC : ulimit -r 0 impossible ; ne pas lancer le moteur sans temps réel" >&2
  exit 2
}

RACINE="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$RACINE/build/organum.com"

if [ ! -x "$BIN" ]; then
  echo "ÉCHEC : $BIN absent ou non exécutable (lancer web/scripts/build.sh)" >&2
  exit 2
fi

# Sur NixOS, libasound n'est pas dans un chemin standard : si l'appelant ne
# l'a pas désignée, prendre la plus ancienne trouvée dans le magasin. Les
# versions récentes, liées à une glibc dont librt n'a pas
# __pointer_chk_guard, échouent avec l'aide de cosmo_dlopen.
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
IGNORES=0

# Arrêt par le PID mémorisé, jamais par nom de processus. SIGKILL est
# volontaire : sur SIGTERM, organum signale son groupe de processus, ce qui
# atteindrait ce script (il partage le groupe). etat.json a déjà été écrit.
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

ok() {
  echo "OK    : $1"
}

echec() {
  echo "ÉCHEC : $1"
  ECHECS=$((ECHECS + 1))
}

# Contrôle volontairement non exécuté (outil absent) : signalé, jamais compté
# comme un succès silencieux.
ignore() {
  echo "IGNORÉ : $1"
  IGNORES=$((IGNORES + 1))
}

# Vérifie qu'une chaîne contient un motif littéral.
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

# lancer [ORGANUM_QUALITE] [ORGANUM_CALIBRATION_FACTEUR] [ORGANUM_REVERB_TETE]
#        [PERIPH] [ORGANUM_PERIODE] [ORGANUM_TAUX] [ORGANUM_LIMITEUR] :
# démarre l'orgue et attend qu'il réponde. Les variables sont propres à ce
# lancement ; PERIPH vaut « null » par défaut, et « - » ne définit pas
# ORGANUM_PERIPHERIQUE (pour éprouver le repli sans sortie audio réelle).
lancer() {
  qualite=$1
  facteur=${2:-}
  tete=${3:-}
  periph=${4:-null}
  periode=${5:-}
  taux=${6:-}
  limiteur=${7:-}
  unset ORGANUM_QUALITE ORGANUM_CALIBRATION_FACTEUR ORGANUM_REVERB_TETE
  unset ORGANUM_PERIPHERIQUE ORGANUM_PERIODE ORGANUM_TAUX ORGANUM_LIMITEUR
  if [ -n "$qualite" ]; then
    export ORGANUM_QUALITE="$qualite"
  fi
  if [ -n "$facteur" ]; then
    export ORGANUM_CALIBRATION_FACTEUR="$facteur"
  fi
  if [ -n "$tete" ]; then
    export ORGANUM_REVERB_TETE="$tete"
  fi
  if [ "$periph" != "-" ]; then
    export ORGANUM_PERIPHERIQUE="$periph"
  fi
  if [ -n "$periode" ]; then
    export ORGANUM_PERIODE="$periode"
  fi
  if [ -n "$taux" ]; then
    export ORGANUM_TAUX="$taux"
  fi
  if [ -n "$limiteur" ]; then
    export ORGANUM_LIMITEUR="$limiteur"
  fi
  ORGANUM_ETAT="$ETAT" \
  ORGANUM_CONFIG_MIDI="$CONFIG" \
  ORGANUM_FENETRE=non \
  "$BIN" -l 127.0.0.1 -p "$PORT" >"$JOURNAL" 2>&1 &
  PID=$!
  unset ORGANUM_QUALITE ORGANUM_CALIBRATION_FACTEUR ORGANUM_REVERB_TETE
  unset ORGANUM_PERIPHERIQUE ORGANUM_PERIODE ORGANUM_TAUX ORGANUM_LIMITEUR
  i=0
  # Le moteur charge ses ressources avant d'écouter : jusqu'à ~2 min sur une
  # machine chargée. Chaque essai est borné pour ne jamais bloquer.
  while [ "$i" -lt 200 ]; do
    if curl -s --connect-timeout 1 --max-time 1 -o /dev/null "$URL/api/orgue"; then
      # Aucun serveur de ce test ne doit avoir obtenu le temps réel.
      if curl -s "$URL/api/orgue" | grep -qF '"temps_reel":true'; then
        echec "temps réel actif malgré ulimit -r 0 (fil audio à 100 % sur null)"
        arreter
        return 1
      fi
      return 0
    fi
    # Le processus a pu mourir au démarrage : ne pas attendre 10 s.
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

get() {
  curl -s "$URL/api/orgue"
}

post() {
  curl -s -X POST -H 'Content-Type: application/json' -d "$1" "$URL/api/orgue"
}

code_post() {
  curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' -d "$1" "$URL/api/orgue"
}

# Laisse le fil audio publier la nouvelle qualité (~40 ms) et le processus
# principal enregistrer etat.json (battement de 2 s).
attendre_publication() {
  sleep 0.3
}

attendre_sauvegarde() {
  sleep 3
}

# Attend qu'une motif littéral apparaisse dans GET /api/orgue (max dixièmes
# de seconde) ; imprime le dernier état lu.
attendre_etat() {
  motif=$1
  max=${2:-30}
  i=0
  while [ "$i" -lt "$max" ]; do
    S=$(get)
    if printf '%s' "$S" | grep -qF -- "$motif"; then
      printf '%s' "$S"
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  printf '%s' "$S"
  return 1
}

# Extrait un champ numérique simple (première occurrence).
champ_num() {
  printf '%s' "$1" | grep -o "\"$2\":[0-9.]*" | head -n 1 | cut -d: -f2
}

# Vérifie qu'une chaîne ne contient pas un motif littéral.
verifie_absent() {
  desc=$1
  motif=$2
  sortie=$3
  if printf '%s' "$sortie" | grep -qF -- "$motif"; then
    echec "$desc (motif « $motif » présent ; vu : $sortie)"
  else
    ok "$desc"
  fi
}

# Contrôle AVEC fenêtre native, sous Xvfb : l'interface ne doit pas modifier
# l'état des jeux en boucle. Démarre l'orgue sur une sortie muette, sans
# ORGANUM_FENETRE=non ; après 3 s, compare /api/orgue à 5 s d'intervalle :
# seq inchangé et tous les « on » identiques. Une variable locale aux branches
# (bug de portée MoonScript) inverserait chaque jeu à chaque image et ferait
# varier seq.
controle_fenetre() {
  if ! command -v Xvfb >/dev/null 2>&1; then
    ignore "contrôle avec fenêtre (Xvfb absent)"
    return 0
  fi
  if ! command -v xdotool >/dev/null 2>&1; then
    ignore "contrôle avec fenêtre (xdotool absent)"
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    ignore "contrôle avec fenêtre (python3 absent)"
    return 0
  fi

  export DISPLAY=localhost:3
  unset WAYLAND_DISPLAY
  XVFB_PID=""
  if ! timeout 2 xdotool getdisplaygeometry >/dev/null 2>&1; then
    echo "INFO  : Xvfb :3 absent, démarrage"
    Xvfb :3 -screen 0 1280x800x24 -listen tcp -ac >"$TMP/xvfb.log" 2>&1 &
    XVFB_PID=$!
    i=0
    while [ "$i" -lt 50 ]; do
      timeout 1 xdotool getdisplaygeometry >/dev/null 2>&1 && break
      sleep 0.1
      i=$((i + 1))
    done
    if ! timeout 1 xdotool getdisplaygeometry >/dev/null 2>&1; then
      echec "contrôle avec fenêtre : Xvfb :3 ne démarre pas"
      kill -KILL "$XVFB_PID" 2>/dev/null || true
      wait "$XVFB_PID" 2>/dev/null || true
      unset DISPLAY
      return 1
    fi
  fi

  PORT_FEN=$((PORT + 20))
  while ! port_libre "$PORT_FEN"; do
    PORT_FEN=$((PORT_FEN + 1))
  done
  URL_FEN="http://127.0.0.1:$PORT_FEN"
  DIR_FEN="$TMP/fenetre"
  mkdir -p "$DIR_FEN"
  PID_FEN=""
  ENFANTS_FEN=""

  arreter_fenetre() {
    for e in $ENFANTS_FEN; do
      kill -KILL "$e" 2>/dev/null || true
    done
    if [ -n "$PID_FEN" ]; then
      kill -KILL "$PID_FEN" 2>/dev/null || true
      wait "$PID_FEN" 2>/dev/null || true
      PID_FEN=""
    fi
    if [ -n "$XVFB_PID" ]; then
      kill -KILL "$XVFB_PID" 2>/dev/null || true
      wait "$XVFB_PID" 2>/dev/null || true
      XVFB_PID=""
    fi
  }

  unset ORGANUM_QUALITE ORGANUM_CALIBRATION_FACTEUR ORGANUM_REVERB_TETE
  unset ORGANUM_PERIPHERIQUE ORGANUM_PERIODE ORGANUM_TAUX ORGANUM_LIMITEUR
  unset ORGANUM_FENETRE ORGANUM_ETAT ORGANUM_CONFIG_MIDI
  ORGANUM_ETAT="$DIR_FEN/etat.json" \
  ORGANUM_CONFIG_MIDI="$DIR_FEN/midi.json" \
  ORGANUM_PERIPHERIQUE=null \
  "$BIN" -l 127.0.0.1 -p "$PORT_FEN" >"$DIR_FEN/journal.log" 2>&1 &
  PID_FEN=$!

  i=0
  while [ "$i" -lt 200 ]; do
    if curl -s --connect-timeout 1 --max-time 1 -o /dev/null "$URL_FEN/api/orgue"; then
      break
    fi
    if ! kill -0 "$PID_FEN" 2>/dev/null; then
      echec "contrôle avec fenêtre : organum s'est arrêté au démarrage"
      sed 's/^/        /' "$DIR_FEN/journal.log" >&2
      arreter_fenetre
      unset DISPLAY
      return 1
    fi
    sleep 0.1
    i=$((i + 1))
  done
  if [ "$i" -ge 200 ]; then
    echec "contrôle avec fenêtre : organum ne répond pas sur $URL_FEN"
    sed 's/^/        /' "$DIR_FEN/journal.log" >&2
    arreter_fenetre
    unset DISPLAY
    return 1
  fi
  if curl -s "$URL_FEN/api/orgue" | grep -qF '"temps_reel":true'; then
    echec "contrôle avec fenêtre : temps réel actif malgré ulimit -r 0"
    arreter_fenetre
    unset DISPLAY
    return 1
  fi

  # Laisse la fenêtre se créer, puis vérifie que le processus fils tourne bien.
  sleep 3
  ENFANTS_FEN=$(pgrep -P "$PID_FEN" 2>/dev/null || true)
  if [ -z "$ENFANTS_FEN" ]; then
    echec "contrôle avec fenêtre : aucun processus de fenêtre lancé"
    sed 's/^/        /' "$DIR_FEN/journal.log" >&2
    arreter_fenetre
    unset DISPLAY
    return 1
  fi

  S1=$(curl -s "$URL_FEN/api/orgue")
  sleep 5
  S2=$(curl -s "$URL_FEN/api/orgue")
  printf '%s' "$S1" >"$DIR_FEN/etat1.json"
  printf '%s' "$S2" >"$DIR_FEN/etat2.json"

  if MESSAGE=$(python3 - "$DIR_FEN/etat1.json" "$DIR_FEN/etat2.json" <<'PY'
import json, sys

a = json.load(open(sys.argv[1]))
b = json.load(open(sys.argv[2]))

def jeux(d):
    return [(i, j, bool(jeu.get("on")))
            for i, div in enumerate(d.get("divisions", []))
            for j, jeu in enumerate(div.get("jeux", []))]

ja, jb = jeux(a), jeux(b)
erreurs = []
if a.get("seq") != b.get("seq"):
    erreurs.append("seq %s -> %s" % (a.get("seq"), b.get("seq")))
if ja != jb:
    diffs = [(x, y) for x, y in zip(ja, jb) if x != y]
    erreurs.append("%d jeu(x) inversé(s) : %s" % (len(diffs), diffs[:5]))
if erreurs:
    print("; ".join(erreurs))
    sys.exit(1)
print("seq=%s, %d jeux identiques" % (a.get("seq"), len(ja)))
PY
  ); then
    ok "fenêtre : état stable ($MESSAGE)"
  else
    echec "fenêtre : état instable ($MESSAGE)"
  fi

  arreter_fenetre
  unset DISPLAY
  return 0
}

# Lint des globales MoonScript : le bug était une variable non déclarée,
# locale à ses branches et donc globale à la lecture. moonc -l signale aussi
# les globales fournies par redbean (Slurp, utf8) et le journal (Log,
# kLogWarn) : la liste explicite ci-dessous les autorise. Toute autre globale
# (nouvelle) fait échouer le contrôle.
controle_globales() {
  if ! command -v moonc >/dev/null 2>&1; then
    ignore "lint des globales MoonScript (moonc absent)"
    return 0
  fi
  SORTIE=$(moonc -l --lint-stage global_access "$RACINE/src/fenetre.moon" 2>&1 || true)
  GLOBALES=$(printf '%s\n' "$SORTIE" |
    sed -n 's/.*accessing global `\([^`]*\)`.*/\1/p' | sort -u)
  NOUVELLES=""
  for g in $GLOBALES; do
    case " Slurp utf8 Log kLogWarn " in
      *" $g "*) ;;
      *) NOUVELLES="$NOUVELLES $g" ;;
    esac
  done
  if [ -n "$NOUVELLES" ]; then
    echec "fenetre.moon : globale(s) non déclarée(s) :$NOUVELLES"
  else
    ok "fenetre.moon : aucune globale nouvelle (autorisées : Slurp, utf8, Log, kLogWarn)"
  fi
}

# Repart d'un premier lancement : ni etat.json ni son fichier de qualité.
effacer_etat() {
  arreter
  rm -f "$ETAT" "$ETAT.qualite.json"
}

unset ORGANUM_QUALITE ORGANUM_REVERB_TETE ORGANUM_CALIBRATION_FACTEUR
# Active le point d'entrée de diagnostic de la règle C du niveau de charge.
ORGANUM_DIAGNOSTIC=1
export ORGANUM_DIAGNOSTIC

# Permet de ne lancer que le contrôle avec fenêtre (démonstration ou mise au
# point, sans attendre toute la suite).
if [ "${TEST_FENETRE_SEUL:-0}" = 1 ]; then
  controle_fenetre
  echo
  if [ "$ECHECS" -eq 0 ]; then
    if [ "$IGNORES" -gt 0 ]; then
      echo "Tous les contrôles exécutés : OK ($IGNORES ignoré(s))"
    else
      echo "Tous les contrôles : OK"
    fi
    exit 0
  fi
  echo "$ECHECS contrôle(s) en échec"
  exit 1
fi

echo "== lint des globales MoonScript (fenetre.moon)"
controle_globales

echo "== démarrage sur le port $PORT (état temporaire $TMP)"
effacer_etat
lancer "" 1 || exit 1

echo "== premier lancement : calibration automatique (facteur 1)"
S=$(get)
verifie "calibration présente" '"calibration":{' "$S"
verifie "calibration : durée renseignée" '"duree_calibration_ms":' "$S"
verifie "calibration : échéance = 10,67 ms (512/48000)" '"echeance_ms":10.6666' "$S"
verifie "calibration : quatre estimations" '"estimation_ms":[' "$S"
verifie "auto par défaut au premier lancement = true" '"auto":true' "$S"
verifie "machine rapide (facteur 1) : niveau le plus haut = 3" '"niveau":3' "$S"
verifie "spatialisation par défaut = 2" '"spatialisation":2' "$S"
verifie "bruit_attaque par défaut = true" '"bruit_attaque":true' "$S"
verifie "instabilite par défaut = true" '"instabilite":true' "$S"
verifie "polyphonie_max par défaut = 0" '"polyphonie_max":0' "$S"
verifie "tete_reverb par défaut = true" '"tete_reverb":true' "$S"
verifie "tete_reverb non imposée par défaut" '"tete_reverb_impose":false' "$S"

echo "== charge : champs exposés et règle du niveau"
if command -v python3 >/dev/null 2>&1; then
  if printf '%s' "$S" | python3 -c '
import json, sys
q = json.load(sys.stdin)["qualite"]
for k in ("charge", "charge_pointe", "charge_niveau", "xruns", "xruns_recents"):
    v = q[k]
    assert isinstance(v, int) and not isinstance(v, bool), k
assert isinstance(q["charge_evaluee"], bool)
assert q["charge_niveau"] in (0, 1, 2, 3)
' 2>/dev/null; then
    ok "champs de charge présents et typés"
  else
    echec "champs de charge absents ou mal typés"
  fi
else
  for champ in '"charge":' '"charge_pointe":' '"charge_evaluee":' '"charge_niveau":' '"xruns_recents":'; do
    verifie "champ de charge présent : $champ" "$champ" "$S"
  done
fi
verifie "sans jeu : niveau non évalué (gris)" '"charge_niveau":0' "$S"
verifie "sans jeu : charge_evaluee faux" '"charge_evaluee":false' "$S"

diag_charge() {
  curl -s "$URL/api/diagnostic/charge?pointe=$1&xruns=$2&evaluee=$3"
}
R=$(diag_charge 50 0 1)
verifie "règle : pointe 50 %, aucun xrun, évalué = vert (1)" '"niveau":1' "$R"
R=$(diag_charge 70 0 1)
verifie "règle : pointe 70 %, aucun xrun = orange (2)" '"niveau":2' "$R"
R=$(diag_charge 95 0 1)
verifie "règle : pointe 95 % = rouge (3)" '"niveau":3' "$R"
R=$(diag_charge 10 3 1)
verifie "règle : 3 xruns récents = rouge (3)" '"niveau":3' "$R"
R=$(diag_charge 20 0 0)
verifie "règle : pas de mesure de jeu = gris (0)" '"niveau":0' "$R"

echo "== pages : /audio séparée de /"
CODE=$(curl -s -o "$TMP/audio.html" -w '%{http_code}' "$URL/audio")
if [ "$CODE" = "200" ]; then
  ok "/audio répond 200"
else
  echec "/audio attendu 200, reçu $CODE"
fi
verifie "/audio contient qualite-niveau" 'qualite-niveau' "$(cat "$TMP/audio.html" 2>/dev/null || true)"
verifie "/audio contient le curseur de réverbération" 'id="reverb"' "$(cat "$TMP/audio.html" 2>/dev/null || true)"
LOCATION=$(curl -s -o /dev/null -D - "$URL/qualite" | tr -d '\r' | grep -i '^Location:' | head -n 1)
CODE=$(curl -s -o /dev/null -w '%{http_code}' "$URL/qualite")
if [ "$CODE" = "302" ]; then
  ok "/qualite redirige (302)"
else
  echec "/qualite attendu 302, reçu $CODE"
fi
verifie "/qualite redirige vers /audio" 'Location: /audio' "$LOCATION"
curl -s "$URL/" >"$TMP/accueil.html"
verifie_absent "/ ne contient plus la section Audio" 'qualite-niveau' "$(cat "$TMP/accueil.html" 2>/dev/null || true)"
verifie_absent "/ ne contient plus le curseur de réverbération" 'id="reverb"' "$(cat "$TMP/accueil.html" 2>/dev/null || true)"
verifie "/ contient un lien vers /audio" 'href="/audio"' "$(cat "$TMP/accueil.html" 2>/dev/null || true)"
verifie "lien Audio : aria-label présent" 'aria-label="Audio —' "$(cat "$TMP/accueil.html" 2>/dev/null || true)"

echo "== POST valide : un seul champ"
R=$(post '{"qualite":{"spatialisation":1}}')
verifie "réponse 200 avec ok" '"ok":true' "$R"
verifie "la réponse reflète la spatialisation demandée = 1" '"spatialisation":1' "$R"
verifie_absent "la réponse ne renvoie pas l'ancienne spatialisation = 2" '"spatialisation":2' "$R"
attendre_publication
S=$(get)
verifie "spatialisation appliquée = 1" '"spatialisation":1' "$S"
verifie "modification individuelle : niveau = -1" '"niveau":-1' "$S"
verifie "modification individuelle : auto = false" '"auto":false' "$S"

echo "== POST valide : plusieurs champs"
R=$(post '{"qualite":{"bruit_attaque":false,"instabilite":false,"polyphonie_max":128}}')
verifie "réponse 200 avec ok" '"ok":true' "$R"
verifie "réponse : bruit_attaque demandé = false" '"bruit_attaque":false' "$R"
verifie "réponse : instabilite demandée = false" '"instabilite":false' "$R"
verifie "réponse : polyphonie_max demandée = 128" '"polyphonie_max":128' "$R"
attendre_publication
S=$(get)
verifie "bruit_attaque appliqué = false" '"bruit_attaque":false' "$S"
verifie "instabilite appliquée = false" '"instabilite":false' "$S"
verifie "polyphonie_max appliquée = 128" '"polyphonie_max":128' "$S"

echo "== POST valide : niveau 1 (présélection d'un coup)"
R=$(post '{"qualite":{"niveau":1}}')
verifie "réponse 200 avec ok" '"ok":true' "$R"
verifie_absent "changement de tête : plus de redemarrage_requis" '"redemarrage_requis"' "$R"
verifie "réponse : niveau demandé = 1" '"niveau":1' "$R"
verifie "réponse : spatialisation demandée = 1" '"spatialisation":1' "$R"
verifie "réponse : polyphonie_max demandée = 128" '"polyphonie_max":128' "$R"
attendre_publication
S=$(get)
verifie "niveau 1 : spatialisation = 1" '"spatialisation":1' "$S"
verifie "niveau 1 : bruit_attaque = false" '"bruit_attaque":false' "$S"
verifie "niveau 1 : instabilite = false" '"instabilite":false' "$S"
verifie "niveau 1 : polyphonie_max = 128" '"polyphonie_max":128' "$S"
verifie "niveau 1 : tete_reverb effective appliquée à chaud = false" '"tete_reverb":false' "$S"
verifie "niveau 1 : tete_reverb_impose = false" '"tete_reverb_impose":false' "$S"
verifie "niveau 1 : niveau = 1" '"niveau":1' "$S"

echo "== POST invalides (400)"
for cas in \
  '{"qualite":{"inconnu":1}}|champ inconnu' \
  '{"qualite":{"bruit_attaque":1}}|type faux' \
  '{"qualite":{"spatialisation":3}}|valeur hors bornes' \
  '{"qualite":{}}|objet vide' \
  '{"qualite":{"polyphonie_max":513}}|polyphonie hors bornes' \
  '{"qualite":{"niveau":4}}|niveau hors bornes' \
  '{"qualite":{"periode":1000}}|période invalide' \
  '{"qualite":{"taux":22050}}|taux invalide' \
  '{"qualite":{"peripherique":"hw:0\u0001"}}|périphérique avec caractère de contrôle' \
  '{"qualite":{"peripherique":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}|périphérique trop long' \
  '{"qualite":{"limiteur":1}}|limiteur non booléen'
do
  corps=${cas%%|*}
  nom=${cas#*|}
  code=$(code_post "$corps")
  if [ "$code" = "400" ]; then
    ok "400 pour $nom"
  else
    echec "400 attendu pour $nom, reçu $code"
  fi
done

echo "== modification individuelle après une présélection"
R=$(post '{"qualite":{"spatialisation":0}}')
verifie "réponse 200 avec ok" '"ok":true' "$R"
attendre_publication
S=$(get)
verifie "spatialisation = 0" '"spatialisation":0' "$S"
verifie "niveau repasse à -1" '"niveau":-1' "$S"

echo "== persistance dans etat.json (réglage manuel, auto faux)"
post '{"qualite":{"niveau":2}}' >/dev/null
attendre_publication
attendre_sauvegarde
verifie "etat.json contient la clé qualite" '"qualite"' "$(cat "$ETAT" 2>/dev/null || true)"
arreter
lancer "" 1 || exit 1
S=$(get)
verifie "après relance : niveau 2 restauré" '"niveau":2' "$S"
verifie "après relance : auto false restauré" '"auto":false' "$S"
verifie "après relance : polyphonie_max = 192" '"polyphonie_max":192' "$S"
verifie "après relance : tete_reverb = true" '"tete_reverb":true' "$S"
verifie_absent "après relance manuelle : pas de recalibration" '"calibration"' "$S"

echo "== ORGANUM_QUALITE=1 prioritaire sur le fichier"
arreter
lancer 1 || exit 1
S=$(get)
verifie "ORGANUM_QUALITE=1 : niveau = 1" '"niveau":1' "$S"
verifie "ORGANUM_QUALITE=1 : spatialisation = 1" '"spatialisation":1' "$S"
verifie "ORGANUM_QUALITE=1 : polyphonie_max = 128" '"polyphonie_max":128' "$S"
verifie "ORGANUM_QUALITE=1 : tete_reverb = false" '"tete_reverb":false' "$S"

echo "== calibration automatique : machine lente (facteur 100)"
effacer_etat
lancer "" 100 || exit 1
S=$(get)
verifie "machine lente : calibration présente" '"calibration":{' "$S"
verifie "machine lente : auto true" '"auto":true' "$S"
verifie "machine lente : niveau retenu = 0" '"niveau":0' "$S"
verifie "niveau 0 : spatialisation = 0" '"spatialisation":0' "$S"
verifie "niveau 0 : bruit_attaque = false" '"bruit_attaque":false' "$S"
verifie "niveau 0 : instabilite = false" '"instabilite":false' "$S"
verifie "niveau 0 : polyphonie_max = 64" '"polyphonie_max":64' "$S"
verifie "niveau 0 : tete_reverb = false" '"tete_reverb":false' "$S"

echo "== modification individuelle en mode auto"
post '{"qualite":{"spatialisation":1}}' >/dev/null
attendre_publication
S=$(get)
verifie "modification : auto passe à false" '"auto":false' "$S"
verifie "modification : niveau = -1" '"niveau":-1' "$S"
attendre_sauvegarde
arreter

echo "== relance sur le même état : pas de recalibration"
lancer "" 1 || exit 1
S=$(get)
verifie_absent "relance manuelle : calibration absente" '"calibration"' "$S"
verifie "relance manuelle : réglage restauré (spatialisation 1)" '"spatialisation":1' "$S"
verifie "relance manuelle : auto reste false" '"auto":false' "$S"
verifie "relance manuelle : niveau reste -1" '"niveau":-1' "$S"

echo "== calibration automatique : machine rapide (facteur 1)"
effacer_etat
lancer "" 1 || exit 1
S=$(get)
verifie "machine rapide : calibration présente" '"calibration":{' "$S"
verifie "machine rapide : auto true" '"auto":true' "$S"
verifie "machine rapide : niveau le plus haut = 3" '"niveau":3' "$S"
verifie "niveau 3 : spatialisation = 2" '"spatialisation":2' "$S"
verifie "niveau 3 : polyphonie_max = 0" '"polyphonie_max":0' "$S"

echo "== ORGANUM_REVERB_TETE=non : la tête effective est coupée"
effacer_etat
lancer 3 1 non || exit 1
S=$(get)
verifie "niveau 3 demandé : tete_reverb configurée = true" '"niveau":3' "$S"
verifie "ORGANUM_REVERB_TETE=non : tete_reverb effective = false" '"tete_reverb":false' "$S"
verifie "ORGANUM_REVERB_TETE=non : tete_reverb_impose = true" '"tete_reverb_impose":true' "$S"
R=$(post '{"qualite":{"tete_reverb":true}}')
verifie "réponse sous contrainte : tete_reverb effective = false" '"tete_reverb":false' "$R"
verifie "réponse sous contrainte : tete_reverb_impose = true" '"tete_reverb_impose":true' "$R"
arreter

echo "== ORGANUM_REVERB_TETE=oui : la tête effective est activée"
effacer_etat
lancer 1 1 oui || exit 1
S=$(get)
verifie "niveau 1 : tete_reverb configurée = false" '"niveau":1' "$S"
verifie "ORGANUM_REVERB_TETE=oui : tete_reverb effective = true" '"tete_reverb":true' "$S"
verifie "ORGANUM_REVERB_TETE=oui : tete_reverb_impose = true" '"tete_reverb_impose":true' "$S"
arreter

echo "== ORGANUM_QUALITE=2 prioritaire sur la calibration auto"
effacer_etat
lancer 2 100 || exit 1
S=$(get)
verifie "ORGANUM_QUALITE=2 : niveau = 2" '"niveau":2' "$S"
verifie "ORGANUM_QUALITE=2 : spatialisation = 1" '"spatialisation":1' "$S"
verifie "ORGANUM_QUALITE=2 : bruit_attaque = true" '"bruit_attaque":true' "$S"
verifie "ORGANUM_QUALITE=2 : instabilite = true" '"instabilite":true' "$S"
verifie "ORGANUM_QUALITE=2 : polyphonie_max = 192" '"polyphonie_max":192' "$S"
verifie "ORGANUM_QUALITE=2 : tete_reverb = true" '"tete_reverb":true' "$S"
verifie "ORGANUM_QUALITE=2 : auto false" '"auto":false' "$S"
verifie_absent "ORGANUM_QUALITE=2 : pas de calibration" '"calibration"' "$S"

arreter

echo "== réglages à chaud : préparation (aucune variable)"
# Aucune variable, y compris ORGANUM_PERIPHERIQUE : « default » est rendu
# muet par ALSA_CONFIG_PATH, jamais la sortie audio réelle.
ALSACONF="$TMP/asound-null.conf"
cat >"$ALSACONF" <<'EOF'
pcm.!default {
    type null
}
EOF
ALSA_CONFIG_PATH="$ALSACONF"
export ALSA_CONFIG_PATH
effacer_etat
# Volume, réverbération et gains non défaut : ils doivent survivre à la
# recréation du moteur lors d'un changement de taux.
printf '%s\n' '{"volume":0.37,"reverb":0.11,"gains":[0.25,0.35,0.45,0.55]}' >"$ETAT"
lancer "" 1 "" "-" || exit 1
S=$(get)
verifie "période effective par défaut = 512" '"periode":512' "$S"
verifie "période enregistrée par défaut = 512" '"periode_prochain":512' "$S"
verifie "période non imposée par défaut" '"periode_impose":false' "$S"
verifie "taux enregistré par défaut = 48000" '"taux_prochain":48000' "$S"
verifie "taux non imposé par défaut" '"taux_impose":false' "$S"
verifie "périphérique par défaut = vide" '"peripherique":""' "$S"
verifie "périphérique non imposé par défaut" '"peripherique_impose":false' "$S"
verifie "limiteur enregistré par défaut = true" '"limiteur_prochain":true' "$S"
verifie "limiteur non imposé par défaut" '"limiteur_impose":false' "$S"
verifie "aucun repli audio au démarrage nominal" '"audio_repli":""' "$S"
verifie "volume initial non défaut" '"volume":0.37' "$S"
verifie "réverbération initiale non défaut" '"reverb":0.1' "$S"

# Prépare un état à préserver : jeu, gain, réverbération, qualité.
post '{"qualite":{"spatialisation":2,"polyphonie_max":123}}' >/dev/null
post '{"stop":{"division":0,"index":0,"on":true}}' >/dev/null
post '{"gain":{"division":0,"value":0.33}}' >/dev/null
post '{"reverb":77}' >/dev/null
attendre_publication
S=$(get)
REV0=$(champ_num "$S" reverb)
XR0=$(champ_num "$S" xruns)
EQ0=$(champ_num "$S" erreurs_ecriture)

echo "== application : état explicite pendant un changement de taux"
R=$(post '{"qualite":{"taux":44100}}')
VU_APPLI=0
if printf '%s' "$R" | grep -qF '"application":true'; then VU_APPLI=1; fi
i=0
while [ "$i" -lt 300 ] && [ "$VU_APPLI" -eq 0 ]; do
  S=$(get)
  if printf '%s' "$S" | grep -qF '"application":true'; then VU_APPLI=1; fi
  sleep 0.01
  i=$((i + 1))
done
if [ "$VU_APPLI" -eq 1 ]; then
  ok "changement de taux : application passe à vrai"
else
  echec "changement de taux : application n'est jamais passé à vrai"
fi
# Le taux effectif est publié par le fil audio au battement suivant : attendre
# d'abord la valeur effective, puis la fin de l'application.
S=$(attendre_etat '"taux":44100' 200) || true
verifie "changement de taux : taux 44100 effectif" '"taux":44100' "$S"
S=$(attendre_etat '"application":false' 100) || true
verifie "changement de taux : application revient à faux" '"application":false' "$S"
post '{"qualite":{"taux":48000}}' >/dev/null
S=$(attendre_etat '"taux":48000' 200) || true
S=$(attendre_etat '"application":false' 100) || true
verifie "retour au taux 48000 : application à faux" '"application":false' "$S"

echo "== application : échec de périphérique puis retour à faux"
post '{"qualite":{"peripherique":"hw:98,98"}}' >/dev/null
S=$(attendre_etat '"audio_erreur":"p' 100) || true
verifie "périphérique inexistant : audio_erreur présent" '"audio_erreur":"p' "$S"
S=$(attendre_etat '"application":false' 100) || true
verifie "périphérique inexistant : application revient à faux" '"application":false' "$S"
post '{"qualite":{"peripherique":""}}' >/dev/null
S=$(attendre_etat '"audio_erreur":""' 100) || true
S=$(attendre_etat '"application":false' 100) || true
verifie "périphérique rétabli : audio_erreur vidé" '"audio_erreur":""' "$S"

echo "== application : 5 demandes de période rapprochées"
for p in 256 1024 128 2048 512; do
  post "{\"qualite\":{\"periode\":$p}}" >/dev/null
  sleep 0.02
done
S=$(attendre_etat '"application":false' 200) || true
verifie "5 demandes rapprochées : application finit à faux" '"application":false' "$S"
verifie "5 demandes rapprochées : période finale = 512" '"periode":512' "$S"

echo "== application : échec de POST avant la commande"
CODE=$(code_post '{"qualite":{"taux":22050}}')
if [ "$CODE" = "400" ]; then
  ok "taux invalide : POST refusé (400)"
else
  echec "taux invalide : 400 attendu, reçu $CODE"
fi
S=$(get)
verifie "POST refusé : application reste à faux" '"application":false' "$S"

echo "== période à chaud, sans relance (moins de 3 s)"
T0=$(date +%s%N)
R=$(post '{"qualite":{"periode":1024}}')
verifie_absent "période : pas de redemarrage_requis" '"redemarrage_requis"' "$R"
S=$(attendre_etat '"periode":1024' 30) || true
T1=$(date +%s%N)
verifie "période effective = 1024 sans relance" '"periode":1024' "$S"
verifie "période enregistrée = 1024" '"periode_prochain":1024' "$S"
verifie "niveau inchangé par la période = -1" '"niveau":-1' "$S"
verifie "auto inchangé par la période = false" '"auto":false' "$S"
echo "durée reconfiguration de période : $(( (T1 - T0) / 1000000 )) ms"
XR1=$(champ_num "$S" xruns)
EQ1=$(champ_num "$S" erreurs_ecriture)
if [ -n "$XR0" ] && [ -n "$XR1" ] && [ -n "$EQ0" ] && [ -n "$EQ1" ] &&
   [ "$XR1" -ge "$XR0" ] && [ "$EQ1" -ge "$EQ0" ]; then
  ok "xruns et erreurs d'écriture cohérents (croissants) après la période"
else
  echec "xruns/erreurs d'écriture incohérents ($XR0→$XR1, $EQ0→$EQ1)"
fi

echo "== fils de requête : oublier_audio ne casse ni l'état ni les commandes"
S=$(get)
verifie "état lisible dans un fil de requête" '"qualite":{' "$S"
R=$(post '{"gain":{"division":3,"value":0.61}}')
verifie "commande acceptée dans un fil de requête" '"ok":true' "$R"
S=$(get)
verifie "commande appliquée dans un fil de requête" '"gain":0.61' "$S"

echo "== charge : un accord tenu fait monter la pointe"
if command -v aplaymidi >/dev/null 2>&1 && command -v aconnect >/dev/null 2>&1 &&
   command -v python3 >/dev/null 2>&1; then
  CLIENT_MIDI=$(env -u ALSA_CONFIG_PATH aplaymidi -l 2>/dev/null | awk '/Organum/ { split($1, a, ":"); print a[1]; exit }')
  if [ -n "$CLIENT_MIDI" ]; then
    python3 - "$TMP/accord-on.mid" "$TMP/accord-off.mid" <<'PYMIDI'
import struct, sys

def vlq(n):
    b = [n & 0x7f]
    n >>= 7
    while n:
        b.insert(0, (n & 0x7f) | 0x80)
        n >>= 7
    return bytes(b)

def fichier(chemin, piste):
    data = (b'MThd' + struct.pack('>IHHH', 6, 0, 1, 480) +
            b'MTrk' + struct.pack('>I', len(piste)) + piste)
    open(chemin, 'wb').write(data)

on = b''.join(vlq(0) + bytes([0x90, n, 100]) for n in (60, 64, 67, 72))
on += vlq(1920) + bytes([0xFF, 0x2F, 0])
fichier(sys.argv[1], on)
fichier(sys.argv[2], bytes([0x00, 0xB0, 123, 0, 0x00, 0xFF, 0x2F, 0]))
PYMIDI
    env -u ALSA_CONFIG_PATH aplaymidi -p "$CLIENT_MIDI:0" "$TMP/accord-on.mid" >/dev/null 2>&1 || true
    sleep 1.2
    CHARGE_POINTE=$(curl -s "$URL/api/orgue" | python3 -c 'import json,sys; print(json.load(sys.stdin)["qualite"]["charge_pointe"])' 2>/dev/null || echo 0)
    CHARGE_EVALUEE=$(curl -s "$URL/api/orgue" | python3 -c 'import json,sys; print("true" if json.load(sys.stdin)["qualite"]["charge_evaluee"] else "false")' 2>/dev/null || echo false)
    env -u ALSA_CONFIG_PATH aplaymidi -p "$CLIENT_MIDI:0" "$TMP/accord-off.mid" >/dev/null 2>&1 || true
    if [ "$CHARGE_EVALUEE" = "true" ] && [ "$CHARGE_POINTE" -gt 0 ] 2>/dev/null; then
      ok "accord tenu : charge évaluée et pointe = $CHARGE_POINTE %"
    else
      echec "accord tenu : charge non évaluée (pointe=$CHARGE_POINTE, évaluée=$CHARGE_EVALUEE)"
    fi
    # Point 3 : un réglage remet réellement la mesure à zéro, y compris le
    # niveau publié (qui fait alors avancer seq) et les xruns récents.
    NIVEAU_AVANT=$(curl -s "$URL/api/orgue" | python3 -c 'import json,sys; print(json.load(sys.stdin)["qualite"]["charge_niveau"])' 2>/dev/null || echo 0)
    SEQ_AVANT=$(curl -s "$URL/api/orgue" | python3 -c 'import json,sys; print(json.load(sys.stdin)["seq"])' 2>/dev/null || echo 0)
    post '{"qualite":{"instabilite":false}}' >/dev/null
    sleep 0.3
    S=$(get)
    NIVEAU_APRES=$(printf '%s' "$S" | python3 -c 'import json,sys; print(json.load(sys.stdin)["qualite"]["charge_niveau"])' 2>/dev/null || echo inconnu)
    RECENTS_APRES=$(printf '%s' "$S" | python3 -c 'import json,sys; print(json.load(sys.stdin)["qualite"]["xruns_recents"])' 2>/dev/null || echo inconnu)
    SEQ_APRES=$(printf '%s' "$S" | python3 -c 'import json,sys; print(json.load(sys.stdin)["seq"])' 2>/dev/null || echo 0)
    if [ "$NIVEAU_AVANT" -gt 0 ] 2>/dev/null && [ "$NIVEAU_APRES" = "0" ] &&
       [ "$RECENTS_APRES" = "0" ] && [ "$SEQ_APRES" -gt "$SEQ_AVANT" ] 2>/dev/null; then
      ok "réglage : mesure remise à zéro (niveau $NIVEAU_AVANT→0, seq $SEQ_AVANT→$SEQ_APRES)"
    else
      echec "réglage : mesure non remise à zéro (niveau $NIVEAU_AVANT→$NIVEAU_APRES, xruns récents=$RECENTS_APRES, seq $SEQ_AVANT→$SEQ_APRES)"
    fi
  else
    echo "INFO  : port MIDI Organum introuvable, mesure de charge non jouée"
    aplaymidi -l 2>&1 | sed 's/^/        /'
  fi
else
  echo "INFO  : aplaymidi/aconnect/python3 absents, mesure de charge non jouée"
fi

echo "== taux à chaud (recréation silencieuse, moins de 15 s)"
T0=$(date +%s%N)
post '{"qualite":{"taux":44100}}' >/dev/null
S=$(attendre_etat '"taux":44100' 150) || true
T1=$(date +%s%N)
verifie "taux effectif = 44100 sans relance" '"taux":44100' "$S"
verifie "taux enregistré = 44100" '"taux_prochain":44100' "$S"
echo "durée changement de taux : $(( (T1 - T0) / 1000000 )) ms"
verifie "après taux : jeu activé conservé" '"name":"Open Diapason 8","on":true' "$S"
verifie "après taux : volume conservé (0,37)" '"volume":0.37' "$S"
verifie "après taux : réverbération conservée" "\"reverb\":$REV0" "$S"
verifie "après taux : gain de division conservé (0,33)" '"gain":0.33' "$S"
verifie "après taux : spatialisation conservée = 2" '"spatialisation":2' "$S"
verifie "après taux : plafond de polyphonie conservé = 123" '"polyphonie_max":123' "$S"
CODE=$(curl -s -o /dev/null -w '%{http_code}' "$URL/api/orgue")
if [ "$CODE" = "200" ]; then
  ok "serveur joignable pendant/après le changement de taux"
else
  echec "serveur muet après le changement de taux (HTTP $CODE)"
fi
XR2=$(champ_num "$S" xruns)
if [ -n "$XR1" ] && [ -n "$XR2" ] && [ "$XR2" -ge "$XR1" ]; then
  ok "xruns restent croissants après le changement de taux"
else
  echec "xruns non croissants après le changement de taux ($XR1→$XR2)"
fi
post '{"qualite":{"taux":48000}}' >/dev/null
S=$(attendre_etat '"taux":48000' 150) || true
verifie "retour au taux 48000 effectif" '"taux":48000' "$S"

echo "== limiteur et tête à chaud"
post '{"qualite":{"limiteur":false,"tete_reverb":false}}' >/dev/null
S=$(attendre_etat '"limiteur":false' 30) || true
verifie "limiteur effectif = false sans relance" '"limiteur":false' "$S"
verifie "limiteur enregistré = false" '"limiteur_prochain":false' "$S"
verifie "tête effective = false sans relance" '"tete_reverb":false' "$S"
verifie "tête enregistrée = false" '"tete_reverb_prochain":false' "$S"

echo "== périphérique à chaud : échec signalé, puis succès"
post '{"qualite":{"peripherique":"hw:99,99"}}' >/dev/null
S=$(attendre_etat '"audio_erreur":"p' 30) || true
verifie "périphérique absent : audio_erreur renseigné" '"audio_erreur":"p' "$S"
verifie "périphérique absent : valeur effective conservée" '"peripherique":""' "$S"
verifie "périphérique absent : valeur enregistrée = hw:99,99" '"peripherique_prochain":"hw:99,99"' "$S"
CODE=$(curl -s -o /dev/null -w '%{http_code}' "$URL/api/orgue")
if [ "$CODE" = "200" ]; then
  ok "serveur joignable malgré le périphérique absent"
else
  echec "serveur muet après le périphérique absent (HTTP $CODE)"
fi
post '{"qualite":{"peripherique":""}}' >/dev/null
S=$(attendre_etat '"audio_erreur":""' 30) || true
verifie "périphérique valide : effectif = défaut" '"peripherique":""' "$S"
verifie "périphérique valide : audio_erreur vidé" '"audio_erreur":""' "$S"

echo "== boucle de 10 changements de période"
for p in 256 512 1024 128 2048 256 512 128 1024 512; do
  post "{\"qualite\":{\"periode\":$p}}" >/dev/null
  sleep 0.1
done
S=$(attendre_etat '"periode":512' 50) || true
verifie "après la boucle : période effective = 512" '"periode":512' "$S"
verifie "après la boucle : pas d'erreur audio" '"audio_erreur":""' "$S"
SEQ1=$(champ_num "$S" seq)
# seq ne s'incrémente qu'au changement : une petite modification prouve que
# le fil audio traite encore les commandes et publie.
post '{"gain":{"division":2,"value":0.61}}' >/dev/null
sleep 0.3
S2=$(get)
SEQ2=$(champ_num "$S2" seq)
if [ -n "$SEQ1" ] && [ -n "$SEQ2" ] && [ "$SEQ2" -gt "$SEQ1" ]; then
  ok "le fil audio tourne encore (seq $SEQ1→$SEQ2)"
else
  echec "le fil audio semble arrêté (seq $SEQ1→$SEQ2)"
fi

echo "== sauvegarde pendant des changements de taux"
(
  for j in 1 2 3 4 5; do
    post "{\"gain\":{\"division\":0,\"value\":0.$((j + 3))}}" >/dev/null
    post "{\"reverb\":$((60 + j))}" >/dev/null
    sleep 0.2
  done
) &
BG=$!
for i in 1 2 3 4 5; do
  if [ $((i % 2)) -eq 1 ]; then T=44100; else T=48000; fi
  post "{\"qualite\":{\"taux\":$T}}" >/dev/null
  post "{\"gain\":{\"division\":1,\"value\":0.$((i + 2))}}" >/dev/null
  sleep 0.1
done
wait "$BG"
post '{"qualite":{"taux":48000}}' >/dev/null
S=$(attendre_etat '"taux":48000' 150) || true
verifie "alternances de taux : taux final = 48000" '"taux":48000' "$S"
CODE=$(curl -s -o /dev/null -w '%{http_code}' "$URL/api/orgue")
if [ "$CODE" = "200" ]; then
  ok "alternances de taux : serveur joignable"
else
  echec "alternances de taux : serveur muet (HTTP $CODE)"
fi
attendre_sauvegarde
if command -v python3 >/dev/null 2>&1; then
  if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$ETAT" 2>/dev/null; then
    ok "etat.json valide après les alternances"
  else
    echec "etat.json invalide après les alternances"
  fi
else
  verifie "etat.json présent après les alternances" '"qualite"' "$(cat "$ETAT" 2>/dev/null || true)"
fi

echo "== persistance après relance (période, tête)"
post '{"qualite":{"periode":1024,"tete_reverb":false}}' >/dev/null
S=$(attendre_etat '"periode":1024' 30) || true
attendre_sauvegarde
verifie "etat.json contient periode" '"periode":1024' "$(cat "$ETAT" 2>/dev/null || true)"
arreter
lancer "" 1 "" "-" || exit 1
S=$(get)
verifie "après relance : période effective = 1024" '"periode":1024' "$S"
verifie "après relance : période enregistrée = 1024" '"periode_prochain":1024' "$S"
verifie "après relance : tete_reverb effective = false" '"tete_reverb":false' "$S"
verifie "après relance : tete_reverb_prochain = false" '"tete_reverb_prochain":false' "$S"

echo "== tête modifiée en mode auto : le choix survit à la relance"
effacer_etat
lancer "" 1 "" "-" || exit 1
S=$(get)
verifie "tête en auto : auto true au premier lancement" '"auto":true' "$S"
verifie "tête en auto : tête enregistrée true" '"tete_reverb_prochain":true' "$S"
R=$(post '{"qualite":{"tete_reverb":false}}')
verifie_absent "tête en auto : pas de redemarrage_requis" '"redemarrage_requis"' "$R"
verifie "tête en auto : tête enregistrée false" '"tete_reverb_prochain":false' "$R"
S=$(attendre_etat '"tete_reverb":false' 30) || true
verifie "tête en auto : tête effective false à chaud" '"tete_reverb":false' "$S"
attendre_sauvegarde
arreter
lancer "" 1 "" "-" || exit 1
S=$(get)
verifie "tête en auto : après relance auto = false" '"auto":false' "$S"
verifie "tête en auto : après relance niveau = -1" '"niveau":-1' "$S"
verifie "tête en auto : après relance tête enregistrée false" '"tete_reverb_prochain":false' "$S"
verifie "tête en auto : après relance tête effective false" '"tete_reverb":false' "$S"
# Prépare le contrôle suivant : une période enregistrée non imposée à 1024.
post '{"qualite":{"periode":1024}}' >/dev/null
attendre_publication
attendre_sauvegarde

echo "== ORGANUM_PERIODE imposé : valeur enregistrée intacte"
arreter
lancer "" 1 "" "-" 256 || exit 1
S=$(get)
verifie "période effective = 256 (imposée)" '"periode":256' "$S"
verifie "periode_impose = true" '"periode_impose":true' "$S"
verifie "période enregistrée reste 1024" '"periode_prochain":1024' "$S"

echo "== repli : périphérique enregistré absent (sortie par défaut muette)"
arreter
# ALSA_CONFIG_PATH fait de « default » un périphérique null : le repli ouvre
# une sortie muette, jamais la sortie audio réelle.
ALSACONF="$TMP/asound-null.conf"
cat >"$ALSACONF" <<'EOF'
pcm.!default {
    type null
}
EOF
ALSA_CONFIG_PATH="$ALSACONF"
export ALSA_CONFIG_PATH
effacer_etat
lancer "" 1 "" "-" || exit 1
R=$(post '{"qualite":{"peripherique":"hw:99,99","periode":1024}}')
verifie "repli : périphérique enregistré = hw:99,99" '"peripherique_prochain":"hw:99,99"' "$R"
verifie_absent "repli : pas de redemarrage_requis" '"redemarrage_requis"' "$R"
attendre_sauvegarde
arreter
lancer "" 1 "" "-" || exit 1
S=$(get)
CODE=$(curl -s -o /dev/null -w '%{http_code}' "$URL/api/orgue")
if [ "$CODE" = "200" ]; then
  ok "repli : le serveur répond malgré le périphérique absent"
else
  echec "repli : le serveur ne répond pas (HTTP $CODE)"
fi
verifie "repli : audio_repli renseigné" '"audio_repli":"r' "$S"
verifie "repli : périphérique enregistré conservé" '"peripherique_prochain":"hw:99,99"' "$S"
verifie "repli : période enregistrée conservée" '"periode_prochain":1024' "$S"
verifie "repli : période effective = 512 (défauts)" '"periode":512' "$S"
verifie_absent "repli : la période enregistrée n'est pas devenue effective" '"periode":1024' "$S"
verifie "repli : périphérique effectif = défaut" '"peripherique":""' "$S"
unset ALSA_CONFIG_PATH

arreter

echo "== volume moteur : action POST distincte du volume système"
effacer_etat
lancer "" 1 "" "-" || exit 1
S=$(get)
verifie "volume moteur présent dans GET" '"volume":' "$S"
SYS_AVANT=$(curl -s "$URL/api/volume")
R=$(post '{"volume":0.25}')
verifie "POST volume 0.25 accepté" '"ok":true' "$R"
S=$(attendre_etat '"volume":0.25' 30) || true
verifie "GET : volume moteur = 0.25" '"volume":0.25' "$S"
SYS_APRES=$(curl -s "$URL/api/volume")
if [ "$SYS_AVANT" = "$SYS_APRES" ]; then
  ok "POST /api/orgue volume : /api/volume inchangé"
else
  echec "POST /api/orgue volume a modifié /api/volume ($SYS_AVANT → $SYS_APRES)"
fi

for BAD in '{"volume":"0.5"}' '{"volume":-0.1}' '{"volume":1.1}' '{"volume":null}' \
           '{"volume":0.25,"reverb":30}'; do
  CODE=$(code_post "$BAD")
  if [ "$CODE" = "400" ]; then
    ok "volume invalide refusé (400) : $BAD"
  else
    echec "volume invalide $BAD : HTTP $CODE au lieu de 400"
  fi
done

attendre_sauvegarde
verifie "etat.json contient le volume moteur 0.25" '"volume":0.25' "$(cat "$ETAT" 2>/dev/null || true)"
arreter
lancer "" 1 "" "-" || exit 1
S=$(get)
verifie "après relance : volume moteur = 0.25" '"volume":0.25' "$S"

echo "== tempérament : GET, POST, invalides, note tenue, rafale, persistance"
effacer_etat
lancer "" 1 "" "-" || exit 1
S=$(get)
verifie "GET contient temperament" '"temperament":' "$S"
verifie "tempérament par défaut = égal (5)" '"temperament":5' "$S"
verifie "tempérament sans erreur au démarrage" '"temperament_erreur":""' "$S"
R=$(post '{"temperament":1}')
verifie "POST tempérament valide : ok" '"ok":true' "$R"
S=$(attendre_etat '"temperament":1' 100) || true
verifie "tempérament appliqué et relu = 1 (mésotonique)" '"temperament":1' "$S"
S=$(attendre_etat '"application":false' 100) || true
verifie "tempérament : application repasse à faux" '"application":false' "$S"
for bad in '11' '-1' '2.5' '"1"' 'true'; do
  code=$(code_post "{\"temperament\":$bad}")
  if [ "$code" = "400" ]; then
    ok "tempérament invalide refusé (400) : $bad"
  else
    echec "tempérament invalide $bad : HTTP $code au lieu de 400"
  fi
done
S=$(get)
verifie "POST invalide : tempérament inchangé = 1" '"temperament":1' "$S"

# Note tenue pendant le changement : le calcul différé ne doit ni planter ni
# arrêter le serveur (même si une bascule rapprochée peut couper la voix).
if command -v aplaymidi >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  CLIENT_MIDI=$(env -u ALSA_CONFIG_PATH aplaymidi -l 2>/dev/null | awk '/Organum/ { split($1, a, ":"); print a[1]; exit }')
  if [ -n "$CLIENT_MIDI" ]; then
    python3 - "$TMP/note-tenue.mid" <<'PYNOTE'
import struct, sys

def vlq(n):
    b = [n & 0x7f]
    n >>= 7
    while n:
        b.insert(0, (n & 0x7f) | 0x80)
        n >>= 7
    return bytes(b)

piste = vlq(0) + bytes([0x90, 60, 100])
piste += vlq(3840) + bytes([0x80, 60, 0]) + vlq(0) + bytes([0xFF, 0x2F, 0])
data = (b'MThd' + struct.pack('>IHHH', 6, 0, 1, 480) +
        b'MTrk' + struct.pack('>I', len(piste)) + piste)
open(sys.argv[1], 'wb').write(data)
PYNOTE
    env -u ALSA_CONFIG_PATH aplaymidi -p "$CLIENT_MIDI:0" "$TMP/note-tenue.mid" >/dev/null 2>&1 &
    MIDI_PID=$!
    sleep 0.4
    R=$(post '{"temperament":2}')
    verifie "note tenue : POST tempérament accepté" '"ok":true' "$R"
    sleep 0.3
    S=$(attendre_etat '"temperament":2' 100) || true
    verifie "note tenue : tempérament appliqué = 2" '"temperament":2' "$S"
    R=$(post '{"temperament":5}')
    verifie "note tenue : second POST accepté" '"ok":true' "$R"
    wait "$MIDI_PID" 2>/dev/null || true
    CODE=$(curl -s -o /dev/null -w '%{http_code}' "$URL/api/orgue")
    if [ "$CODE" = "200" ]; then
      ok "note tenue : serveur vivant après le changement"
    else
      echec "note tenue : serveur muet après le changement (HTTP $CODE)"
    fi
  else
    echo "INFO  : port MIDI Organum introuvable, note tenue non jouée"
  fi
else
  echo "INFO  : aplaymidi/python3 absents, note tenue non jouée"
fi

# Survivance au changement de taux (le moteur est recréé).
post '{"temperament":3}' >/dev/null
S=$(attendre_etat '"temperament":3' 100) || true
post '{"qualite":{"taux":44100}}' >/dev/null
S=$(attendre_etat '"taux":44100' 200) || true
S=$(attendre_etat '"application":false' 100) || true
verifie "changement de taux : tempérament conservé = 3" '"temperament":3' "$S"
post '{"qualite":{"taux":48000}}' >/dev/null
S=$(attendre_etat '"taux":48000' 200) || true
S=$(attendre_etat '"application":false' 100) || true
verifie "retour taux 48000 : tempérament toujours 3" '"temperament":3' "$S"

# Cinq demandes rapprochées : seule la dernière compte, serveur vivant.
for t in 0 2 7 3 9; do
  post "{\"temperament\":$t}" >/dev/null
  sleep 0.02
done
S=$(attendre_etat '"application":false' 200) || true
verifie "5 demandes rapprochées : application finit à faux" '"application":false' "$S"
verifie "5 demandes rapprochées : la dernière gagne (9)" '"temperament":9' "$S"
CODE=$(curl -s -o /dev/null -w '%{http_code}' "$URL/api/orgue")
if [ "$CODE" = "200" ]; then
  ok "5 demandes rapprochées : serveur vivant"
else
  echec "5 demandes rapprochées : serveur muet (HTTP $CODE)"
fi

# Persistance : clé temperament d'etat.json, relue au lancement suivant.
attendre_sauvegarde
verifie "etat.json contient temperament" '"temperament":9' "$(cat "$ETAT" 2>/dev/null || true)"
arreter
lancer "" 1 "" "-" || exit 1
S=$(get)
verifie "après relance : tempérament 9 restauré" '"temperament":9' "$S"

echo "== pédale MIDI associée à volume : e.volume évolue, /api/volume intact"
if command -v python3 >/dev/null 2>&1 &&
   command -v aplaymidi >/dev/null 2>&1; then
  CLIENT_MIDI=$(env -u ALSA_CONFIG_PATH aplaymidi -l 2>/dev/null | awk '/Organum/ { split($1, a, ":"); print a[1]; exit }')
  if [ -n "$CLIENT_MIDI" ]; then
    R=$(curl -s -X POST -H 'Content-Type: application/json' \
      -d '{"associations":[{"cc":1,"cible":"volume"}]}' "$URL/api/midi")
    verifie "association CC1 -> volume enregistrée" '"cible":"volume"' "$R"
    sleep 0.2
    if command -v aseqsend >/dev/null 2>&1; then
      env -u ALSA_CONFIG_PATH aseqsend -p "$CLIENT_MIDI:0" "b0 01 40" >/dev/null 2>&1 || true
    else
      python3 - "$TMP/cc-volume.mid" <<'PYCC'
import struct, sys
piste = bytes([0x00, 0xB0, 1, 64, 0x00, 0xFF, 0x2F, 0x00])
data = (b'MThd' + struct.pack('>IHHH', 6, 0, 1, 480) +
        b'MTrk' + struct.pack('>I', len(piste)) + piste)
open(sys.argv[1], 'wb').write(data)
PYCC
      env -u ALSA_CONFIG_PATH aplaymidi -p "$CLIENT_MIDI:0" "$TMP/cc-volume.mid" >/dev/null 2>&1 || true
    fi
    sleep 0.4
    S=$(get)
    VOL_MIDI=$(printf '%s' "$S" | python3 -c 'import json,sys; print(json.load(sys.stdin)["volume"])' 2>/dev/null || echo inconnu)
    if python3 - "$VOL_MIDI" <<'PYVOL'
import sys
try:
    v = float(sys.argv[1])
except ValueError:
    sys.exit(1)
sys.exit(0 if abs(v - 64 / 127.0) < 0.01 else 1)
PYVOL
    then
      ok "CC1=64 : e.volume = $VOL_MIDI"
    else
      echec "CC1=64 : e.volume inattendu ($VOL_MIDI)"
    fi
    SYS_MIDI=$(curl -s "$URL/api/volume")
    if [ "$SYS_AVANT" = "$SYS_MIDI" ]; then
      ok "pédale MIDI : /api/volume inchangé"
    else
      echec "pédale MIDI a modifié /api/volume ($SYS_AVANT → $SYS_MIDI)"
    fi
  else
    echo "INFO  : port MIDI Organum introuvable, pédale non simulée"
  fi
else
  echo "INFO  : python3/aplaymidi absents, pédale non simulée"
fi
arreter

echo "== fenêtre native : état stable sous Xvfb"
controle_fenetre

echo
if [ "$ECHECS" -eq 0 ]; then
  if [ "$IGNORES" -gt 0 ]; then
    echo "Tous les contrôles exécutés : OK ($IGNORES ignoré(s))"
  else
    echo "Tous les contrôles : OK"
  fi
  exit 0
fi
echo "$ECHECS contrôle(s) en échec"
exit 1
