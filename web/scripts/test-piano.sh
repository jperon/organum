#!/bin/sh
# Piano échantillonné : chargement, aiguillage MIDI par division, sustain,
# arrêt propre, et mesure de charge avec et sans piano.
#
# Lance web/build/organum.com sur une sortie muette (ORGANUM_PERIPHERIQUE=null)
# et un état temporaire ; les notes viennent de l'API HTTP (CMD_MIDI) et la
# pédale de sustain d'un faux assistant MIDI par socket
# (plateforme/tests/faux_assistant.c), comme test-midi-socket.sh. Aucun son
# n'est produit.
#
# Contrôles :
#   a. le piano est disponible et son volume par défaut vaut 0,5 ;
#   b. l'API active le piano sur une division, et l'état le publie ;
#   c. 48 notes jouées avec la pédale enfoncée donnent piano_voix ≥ 48, et
#      les relâchements sont retenus par la pédale (piano_voix reste ≥ 48) ;
#   d. pédale relevée : les notes retenues sont relâchées (piano_voix → 0) ;
#   e. couper le drapeau relâche les notes piano de la division ;
#   f. panic relâche aussi le piano ;
#   g. aucun xrun nouveau pendant les fenêtres mesurées ; la charge avec piano
#      est rapportée à côté de la charge sans piano ;
#   h. le volume du piano est borné par l'API (400 hors 0..1) ;
#   i. la persistance enregistre le volume et les drapeaux du piano.
#
# Sortie : une ligne OK/ÉCHEC par contrôle ; code non nul au premier échec.
set -u

# Règles de sûreté d'AGENTS.md : jamais de temps réel (la sortie null rendrait
# le fil audio à 100 % d'un cœur), jamais d'affichage hérité.
ulimit -r 0 2>/dev/null || {
  echo "ÉCHEC : ulimit -r 0 impossible ; ne pas lancer le moteur sans temps réel" >&2
  exit 2
}
unset WAYLAND_DISPLAY DISPLAY
unset ORGANUM_SANS_BACKEND ORGANUM_MIDI_SOCKET ORGANUM_AUDIO_SOCKET
unset ORGANUM_FENETRE ORGANUM_PERIPHERIQUE ORGANUM_QUALITE

RACINE="$(cd "$(dirname "$0")/.." && pwd)"
DEPOT="$(cd "$RACINE/.." && pwd)"
BIN="$RACINE/build/organum.com"
SOURCE_ASSISTANT="$DEPOT/plateforme/tests/faux_assistant.c"
if [ ! -x "$BIN" ]; then
  echo "ÉCHEC : $BIN absent ou non exécutable (lancer web/scripts/build.sh)" >&2
  exit 2
fi
if [ ! -f "$SOURCE_ASSISTANT" ]; then
  echo "ÉCHEC : $SOURCE_ASSISTANT absent" >&2
  exit 2
fi

# Sur NixOS, libasound n'est pas dans un chemin standard (voir test-qualite.sh).
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
SOCKET="$TMP/midi.sock"
JOURNAL="$TMP/serveur.log"
JOURNAL_ASSISTANT="$TMP/assistant.log"
ASSISTANT="$TMP/faux_assistant"
SERVEUR_PID=""
ASSISTANT_PID=""
ECHECS=0

arreter_serveur() {
  if [ -n "$SERVEUR_PID" ]; then
    # SIGKILL : sur SIGTERM, organum signale tout son groupe, donc ce script.
    kill -KILL "$SERVEUR_PID" 2>/dev/null || true
    wait "$SERVEUR_PID" 2>/dev/null || true
    SERVEUR_PID=""
  fi
}
arreter_assistant() {
  if [ -n "$ASSISTANT_PID" ]; then
    # SIGTERM est légitime : l'assistant ne propage pas au groupe.
    kill -TERM "$ASSISTANT_PID" 2>/dev/null || true
    wait "$ASSISTANT_PID" 2>/dev/null || true
    ASSISTANT_PID=""
  fi
}
nettoyer() {
  arreter_assistant
  arreter_serveur
  rm -rf "$TMP"
}
trap nettoyer EXIT
trap 'nettoyer; exit 130' INT TERM

ok() { echo "OK    : $1"; }
echec() { echo "ÉCHEC : $1"; ECHECS=$((ECHECS + 1)); }

verifie() {
  if [ "$2" = "$3" ]; then
    ok "$1 ($3)"
  else
    echec "$1 (attendu $2, vu $3)"
  fi
}
verifie_vrai() {
  desc=$1
  shift
  if "$@"; then ok "$desc"; else echec "$desc"; fi
}

port_libre() {
  ! curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$1/api/orgue" 2>/dev/null
}

PORT="${PORT:-8099}"
for p in "$PORT" 8108 8109 8110 8111 8112 8113; do
  if port_libre "$p"; then
    PORT=$p
    break
  fi
done
URL="http://127.0.0.1:$PORT"

if ! cc -O2 -Wall -Wextra -std=c11 -o "$ASSISTANT" "$SOURCE_ASSISTANT" \
    >"$TMP/compilation.log" 2>&1; then
  echo "ÉCHEC : compilation du faux assistant" >&2
  sed 's/^/        /' "$TMP/compilation.log" >&2
  exit 2
fi

# --- Aides JSON (sans jq) ---------------------------------------------------
# champ <json> <clé> : première valeur scalaire de la clé.
champ() {
  printf '%s' "$1" | tr ',' '\n' | sed -n "s/.*\"$2\":\\([^,}]*\\).*/\\1/p" |
    head -n 1 | tr -d ' "' | tr -d '\n'
}
etat_json() { curl -s --max-time 2 "$URL/api/orgue"; }
midi_json() { curl -s --max-time 2 "$URL/api/midi"; }
# drapeau_piano <json> : « true »/« false » du piano de la première division.
drapeau_piano() {
  printf '%s' "$1" | sed 's/},{/}\n{/g' | sed -n '1p' |
    sed -n 's/.*"piano":\([a-z]*\).*/\1/p'
}
attendre_champ() {  # <clé> <motif> <secondes>
  _cle=$1 _motif=$2 _limite=$3 _i=0
  while [ "$_i" -lt $((_limite * 10)) ]; do
    [ "$(champ "$(etat_json)" "$_cle")" = "$_motif" ] && return 0
    sleep 0.1
    _i=$((_i + 1))
  done
  return 1
}
attendre_au_moins() {  # <clé> <seuil> <secondes>
  _cle=$1 _seuil=$2 _limite=$3 _i=0
  while [ "$_i" -lt $((_limite * 10)) ]; do
    _vu=$(champ "$(etat_json)" "$_cle")
    [ -n "$_vu" ] && [ "$_vu" -ge "$_seuil" ] 2>/dev/null && return 0
    sleep 0.1
    _i=$((_i + 1))
  done
  return 1
}
attendre_au_plus() {  # <clé> <seuil> <secondes>
  _cle=$1 _seuil=$2 _limite=$3 _i=0
  while [ "$_i" -lt $((_limite * 10)) ]; do
    _vu=$(champ "$(etat_json)" "$_cle")
    [ -z "$_vu" ] && _vu=0
    [ "$_vu" -le "$_seuil" ] 2>/dev/null && return 0
    sleep 0.1
    _i=$((_i + 1))
  done
  return 1
}
# attendre_activite_midi <secondes> : au moins un canal actif sur /api/midi.
attendre_activite_midi() {
  _limite=$1 _i=0
  while [ "$_i" -lt $((_limite * 10)) ]; do
    midi_json | grep -qF '"canaux_actifs":[1' && return 0
    sleep 0.1
    _i=$((_i + 1))
  done
  return 1
}

poster() { curl -s --max-time 3 -X POST -H 'Content-Type: application/json' -d "$1" "$URL/api/orgue"; }
# note <note> <vélocité> : note du clavier web sur le canal 1 (division 0).
note() { poster "{\"note\":{\"canal\":1,\"note\":$1,\"velocite\":$2,\"actif\":true}}" >/dev/null; }
relache() { poster "{\"note\":{\"canal\":1,\"note\":$1,\"actif\":false}}" >/dev/null; }
jouer_accord() {  # <nombre> <vélocité> [première note, 40 par défaut]
  _n=$1 _v=$2 _prem=${3:-40} _i=0
  while [ "$_i" -lt "$_n" ]; do
    note $((_prem + _i)) "$_v"
    _i=$((_i + 1))
  done
}
relacher_accord() {  # <nombre> [première note, 40 par défaut]
  _n=$1 _prem=${2:-40} _i=0
  while [ "$_i" -lt "$_n" ]; do
    relache $((_prem + _i))
    _i=$((_i + 1))
  done
}

# --- Serveur ----------------------------------------------------------------
: >"$JOURNAL"
ORGANUM_MIDI_SOCKET="$SOCKET" \
ORGANUM_PERIPHERIQUE=null \
ORGANUM_ETAT="$ETAT" \
ORGANUM_CONFIG_MIDI="$CONFIG" \
ORGANUM_FENETRE=non \
"$BIN" -l 127.0.0.1 -p "$PORT" >"$JOURNAL" 2>&1 &
SERVEUR_PID=$!
i=0
while [ "$i" -lt 400 ]; do
  if curl -s --connect-timeout 1 --max-time 1 -o /dev/null "$URL/api/orgue"; then
    break
  fi
  if ! kill -0 "$SERVEUR_PID" 2>/dev/null; then
    echo "ÉCHEC : organum s'est arrêté au démarrage" >&2
    sed 's/^/        /' "$JOURNAL" >&2
    exit 1
  fi
  sleep 0.05
  i=$((i + 1))
done
if [ "$i" -ge 400 ]; then
  echec "pas de réponse de l'API dans le délai"
  sed 's/^/        /' "$JOURNAL" >&2
  exit 1
fi
verifie "temps réel désactivé malgré le lancement" false \
  "$(champ "$(etat_json)" temps_reel)"

# --- a. piano chargé, volume par défaut ------------------------------------
verifie "piano disponible (SoundFont embarqué chargé)" true \
  "$(champ "$(etat_json)" piano_disponible)"
verifie "volume du piano par défaut" 0.5 "$(champ "$(etat_json)" piano_volume)"
verifie "aucune voix piano au repos" 0 "$(champ "$(etat_json)" piano_voix)"

# --- charge : orgue seul, puis orgue + piano ------------------------------
# Un jeu tiré, sinon l'orgue ne produit aucune voix et la charge ne dit rien.
poster '{"stop":{"division":0,"index":0,"on":true}}' >/dev/null
# mesure_charge <prises> : médiane des « charge » lues à une seconde
# d'intervalle (la machine est partagée : une lecture isolée varie du simple
# au double pour la même charge).
mesure_charge() {
  _n=$1 _i=0 _vals=""
  while [ "$_i" -lt "$_n" ]; do
    sleep 1
    _vals="$_vals $(champ "$(etat_json)" charge)"
    _i=$((_i + 1))
  done
  printf '%s\n' $_vals | sort -n | sed -n "$(( (_n + 1) / 2 ))p"
}

xruns_avant=$(champ "$(etat_json)" xruns)
jouer_accord 24 100 48
verifie "orgue seul : canaux MIDI actifs" true \
  "$(midi_json | grep -qF '"canaux_actifs":[1' && echo true || echo false)"
verifie "aucune voix piano drapeau à faux" 0 "$(champ "$(etat_json)" piano_voix)"
charge_avant=$(mesure_charge 5)
xruns_orgue=$(champ "$(etat_json)" xruns)
relacher_accord 24 48
sleep 1.2

# --- b. activation par l'API ------------------------------------------------
verifie "activation du piano sur la division 1 acceptée" '{"ok":true}' \
  "$(poster '{"piano":{"division":0,"actif":true}}')"
if attendre_champ piano true 10; then
  ok "drapeau piano publié pour la division 1"
else
  echec "drapeau piano non publié ($(drapeau_piano "$(etat_json)"))"
fi
verifie "volume du piano hors bornes refusé" '"piano_volume hors limites"' \
  "$(poster '{"piano_volume":1.5}' | sed 's/^{"error"://; s/}$//')"

# Mêmes 24 notes, piano en plus : l'écart de charge est celle du piano.
jouer_accord 24 100 48
attendre_au_moins piano_voix 24 10 || true
charge_piano=$(mesure_charge 5)
xruns_piano=$(champ "$(etat_json)" xruns)
verifie "aucun xrun nouveau pendant la mesure avec piano" "$xruns_orgue" \
  "$xruns_piano"
relacher_accord 24 48
sleep 1.2

# --- c. 48 notes avec pédale, relâchements retenus -------------------------
# Un premier assistant enfonce la pédale (CC 64 = 127) et la garde enfoncée :
# aucune fenêtre de temps ne borne l'envoi des 48 notes, ce qui rend le test
# insensible à la charge de la machine. L'activité MIDI de /api/midi (premier
# message de la séquence) sert de point de synchronisation.
: >"$JOURNAL_ASSISTANT"
"$ASSISTANT" --socket "$SOCKET" --attendre-client 5000 \
  --sequence "cc:0:64:127,pause:60000" >>"$JOURNAL_ASSISTANT" 2>&1 &
ASSISTANT_PID=$!
if attendre_activite_midi 10; then
  ok "pédale enfoncée reçue (CC 64 = 127)"
else
  echec "pédale enfoncée non reçue (aucune activité MIDI)"
  sed 's/^/        /' "$JOURNAL_ASSISTANT" >&2
fi

# Notes 21..68 : leurs échantillons durent tous plus de 3 s, donc aucun ne
# s'éteint tout seul pendant la mesure (les aigus, non bouclés, si).
jouer_accord 48 100 21
if attendre_au_moins piano_voix 48 20; then
  ok "48 notes simultanées au piano ($(champ "$(etat_json)" piano_voix) voix)"
else
  echec "piano_voix < 48 après l'accord ($(champ "$(etat_json)" piano_voix))"
fi
verifie "aucun xrun récent avec 48 voix piano" 0 \
  "$(champ "$(etat_json)" xruns_recents)"
relacher_accord 48 21
sleep 0.8
voix_tenues=$(champ "$(etat_json)" piano_voix)
# Toutes les notes sont relâchées depuis 0,8 s : seules la pédale les tient.
verifie_vrai "relâchements retenus par la pédale (piano_voix = $voix_tenues ≥ 46)" \
  test "${voix_tenues:-0}" -ge 46
echo "        charge : orgue seul ${charge_avant} %, orgue + piano ${charge_piano} % (pointe $(champ "$(etat_json)" charge_pointe) %)"

# --- d. pédale relevée → notes relâchées ------------------------------------
# Le premier assistant est arrêté (la pédale reste enfoncée dans le piano),
# un second envoie CC 64 = 0 : organum se reconnecte en ~1 s.
arreter_assistant
"$ASSISTANT" --socket "$SOCKET" --attendre-client 5000 \
  --sequence "cc:0:64:0,pause:30000" >>"$JOURNAL_ASSISTANT" 2>&1 &
ASSISTANT_PID=$!
if attendre_au_plus piano_voix 0 15; then
  ok "pédale relevée : notes retenues relâchées"
else
  echec "notes piano encore actives après la pédale ($(champ "$(etat_json)" piano_voix))"
fi

# --- e. couper le drapeau relâche les notes piano ---------------------------
jouer_accord 12 100
attendre_au_moins piano_voix 12 10 || true
verifie "désactivation du piano acceptée" '{"ok":true}' \
  "$(poster '{"piano":{"division":0,"actif":false}}')"
if attendre_au_plus piano_voix 0 6; then
  ok "drapeau coupé : notes piano relâchées"
else
  echec "drapeau coupé : notes piano encore actives ($(champ "$(etat_json)" piano_voix))"
fi
sleep 0.2
verifie "drapeau piano publié à faux" false "$(drapeau_piano "$(etat_json)")"
verifie "aucune voix piano drapeau coupé" 0 "$(champ "$(etat_json)" piano_voix)"
relacher_accord 12
sleep 0.4

# --- f. panic relâche aussi le piano ----------------------------------------
poster '{"piano":{"division":0,"actif":true}}' >/dev/null
attendre_champ piano true 10 || true
jouer_accord 12 100
attendre_au_moins piano_voix 12 10 || true
verifie "panique acceptée" '{"ok":true}' "$(poster '{"panic":true}')"
if attendre_au_plus piano_voix 0 6; then
  ok "panique : piano relâché"
else
  echec "panique : notes piano encore actives ($(champ "$(etat_json)" piano_voix))"
fi
verifie "aucun xrun nouveau sur toute la séquence" "$xruns_avant" \
  "$(champ "$(etat_json)" xruns)"

# --- h. volume borné par la validation -------------------------------------
verifie "volume du piano négatif refusé" '"piano_volume hors limites"' \
  "$(poster '{"piano_volume":-1}' | sed 's/^{"error"://; s/}$//')"
verifie "volume du piano accepté (0,8)" '{"ok":true}' \
  "$(poster '{"piano_volume":0.8}')"
sleep 0.4
volume_publie=$(champ "$(etat_json)" piano_volume)
if awk -v v="$volume_publie" 'BEGIN { exit !(v > 0.79 && v < 0.81) }'; then
  ok "volume du piano publié ($volume_publie, soit 0,8)"
else
  echec "volume du piano non publié ($volume_publie)"
fi

# --- i. persistance --------------------------------------------------------
sleep 2.5  # un battement de sauvegarde (OnServerHeartbeat, 2 s)
if [ -f "$ETAT" ]; then
  if grep -q '"pianos":\[true' "$ETAT" && grep -q '"piano_volume":0.8' "$ETAT"; then
    ok "état enregistré (piano de la division 1 et volume 0,8)"
  else
    echec "état enregistré sans les champs du piano"
  fi
else
  echec "etat.json non écrit"
fi

echo
if [ "$ECHECS" -ne 0 ]; then
  echo "$ECHECS échec(s)"
  echo "---- journal du serveur ----"
  sed 's/^/        /' "$JOURNAL"
  echo "---- journal de l'assistant ----"
  sed 's/^/        /' "$JOURNAL_ASSISTANT"
  exit 1
fi
ok "piano : tous les contrôles sont passés"
