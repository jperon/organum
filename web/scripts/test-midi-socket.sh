#!/bin/sh
# Test réel du backend MIDI par socket macOS, sous Linux.
#
# ORGANUM_MIDI_SOCKET impose le backend socket à la place d'ALSA. Un faux
# assistant (plateforme/tests/faux_assistant.c, compilé avec le cc de l'hôte)
# joue CoreMIDI : il publie deux claviers, rejoue des notes, des contrôleurs
# et un Program Change, tombe et se relance. On vérifie le chemin complet
# socket → backend → fil audio → moteur → API HTTP.
#
# Contrôles :
#   a. la variable suffit à choisir le backend socket sous Linux ;
#   b. note ON visible dans canaux_actifs (/api/midi), note OFF effacée
#      après ~250 ms ;
#   c. Program Change 0xCF visible dans l'étape du séquenceur (/api/orgue) ;
#   d. deux ports, client « CoreMIDI », connectés ;
#   e. sans assistant, le serveur démarre, l'API répond et ports = [] ;
#   f. après mort et relance de l'assistant, une note est reçue en ≤ 2 s ;
#   g. version refusée : pas de boucle, pas de plantage, ports = [].
#
# Sortie : une ligne OK/ÉCHEC par contrôle ; code non nul au premier échec.
set -u

# Règles de sûreté communes aux tests réels du dépôt.
ulimit -r 0 2>/dev/null || {
  echo "ÉCHEC : ulimit -r 0 impossible ; ne pas lancer le moteur sans temps réel" >&2
  exit 2
}
unset WAYLAND_DISPLAY DISPLAY
unset ORGANUM_SANS_BACKEND ORGANUM_MIDI_SOCKET ORGANUM_FENETRE ORGANUM_PERIPHERIQUE

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
    kill -KILL "$SERVEUR_PID" 2>/dev/null || true
    wait "$SERVEUR_PID" 2>/dev/null || true
    SERVEUR_PID=""
  fi
}
arreter_assistant() {
  if [ -n "$ASSISTANT_PID" ]; then
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

# lancer_serveur [degrade] : démarre organum avec le backend socket, attend
# l'API et vérifie que le fil audio n'a pas obtenu le temps réel (ulimit -r 0).
# « degrade » ajoute ORGANUM_SANS_BACKEND=1 : l'axe audio tombe, pas le MIDI.
lancer_serveur() {
  mode=${1:-}
  : >"$JOURNAL"
  if [ "$mode" = degrade ]; then
    ORGANUM_SANS_BACKEND=1 \
    ORGANUM_MIDI_SOCKET="$SOCKET" \
    ORGANUM_PERIPHERIQUE=null \
    ORGANUM_ETAT="$ETAT" \
    ORGANUM_CONFIG_MIDI="$CONFIG" \
    ORGANUM_FENETRE=non \
    "$BIN" -l 127.0.0.1 -p "$PORT" >"$JOURNAL" 2>&1 &
  else
    ORGANUM_MIDI_SOCKET="$SOCKET" \
    ORGANUM_PERIPHERIQUE=null \
    ORGANUM_ETAT="$ETAT" \
    ORGANUM_CONFIG_MIDI="$CONFIG" \
    ORGANUM_FENETRE=non \
    "$BIN" -l 127.0.0.1 -p "$PORT" >"$JOURNAL" 2>&1 &
  fi
  SERVEUR_PID=$!
  i=0
  while [ "$i" -lt 200 ]; do
    if curl -s --connect-timeout 1 --max-time 1 -o /dev/null "$URL/api/orgue"; then
      if curl -s "$URL/api/orgue" | grep -qF '"temps_reel":true'; then
        echec "temps réel actif malgré ulimit -r 0"
        arreter_serveur
        return 1
      fi
      return 0
    fi
    if ! kill -0 "$SERVEUR_PID" 2>/dev/null; then
      echo "ÉCHEC : organum s'est arrêté au démarrage" >&2
      sed 's/^/        /' "$JOURNAL" >&2
      return 1
    fi
    sleep 0.05
    i=$((i + 1))
  done
  echec "pas de réponse de l'API dans le délai"
  sed 's/^/        /' "$JOURNAL" >&2
  arreter_serveur
  return 1
}

# lancer_assistant <séquence> [options...]
lancer_assistant() {
  sequence=$1
  shift
  : >"$JOURNAL_ASSISTANT"
  "$ASSISTANT" --socket "$SOCKET" --sequence "$sequence" "$@" \
    >"$JOURNAL_ASSISTANT" 2>&1 &
  ASSISTANT_PID=$!
  i=0
  while [ "$i" -lt 100 ]; do
    [ -S "$SOCKET" ] && return 0
    if ! kill -0 "$ASSISTANT_PID" 2>/dev/null; then
      echo "ÉCHEC : le faux assistant s'est arrêté avant d'écouter" >&2
      sed 's/^/        /' "$JOURNAL_ASSISTANT" >&2
      return 1
    fi
    sleep 0.02
    i=$((i + 1))
  done
  echec "socket du faux assistant absente dans le délai"
  sed 's/^/        /' "$JOURNAL_ASSISTANT" >&2
  return 1
}

# attendre_motif <url> <motif> <essais> : rend le dernier corps lu ; code 0
# dès que le motif apparaît.
attendre_motif() {
  url=$1
  motif=$2
  essais=$3
  i=0
  corps=""
  while [ "$i" -lt "$essais" ]; do
    corps=$(curl -s --max-time 2 "$url")
    if printf '%s' "$corps" | grep -qF -- "$motif"; then
      printf '%s' "$corps"
      return 0
    fi
    sleep 0.05
    i=$((i + 1))
  done
  printf '%s' "$corps"
  return 1
}

# --- a/e. Backend socket seul, sans assistant ------------------------------
if lancer_serveur; then
  code=$(curl -s -o "$TMP/orgue.json" -w '%{http_code}' --max-time 2 "$URL/api/orgue")
  verifie "a : GET /api/orgue répond 200" 200 "$code"
  corps=$(cat "$TMP/orgue.json")
  verifie "a : backend socket choisi sous Linux (midi_disponible)" \
    '"midi_disponible":true' "$corps"
  verifie "a : plate-forme toujours linux" '"plateforme":"linux"' "$corps"
  ports=$(curl -s --max-time 2 "$URL/api/midi/ports")
  verifie "e : sans assistant, aucun port" '"ports":[]' "$ports"
  verifie "e : MIDI reste disponible" '"disponible":true' "$ports"
  verifie "e : backend socket annoncé" '"socket":true' "$ports"
  # Précondition du message « assistant absent » de /midi : socket actif et
  # assistant non connecté (la page teste etatPorts.socket === true).
  verifie "e : assistant signalé absent" '"assistant":false' "$ports"
  sleep 1
  refuse "e : aucun message fatal au journal" 'panique' "$(cat "$JOURNAL")"
  refuse "e : pas de plantage au journal" 'Segmentation' "$(cat "$JOURNAL")"
  if kill -0 "$SERVEUR_PID" 2>/dev/null; then
    ok "e : le serveur vit toujours sans assistant"
  else
    echec "e : le serveur s'est arrêté sans assistant"
  fi
fi

# --- b/d. Note, ports et note OFF -----------------------------------------
if lancer_assistant 'note:0:60:100,pause:2000,note:0:60:0' --attendre-client 5000; then
  if corps=$(attendre_motif "$URL/api/midi" '"canaux_actifs":[1' 80); then
    ok "b : note ON visible (canal 1 actif)"
  else
    echec "b : note ON non visible dans canaux_actifs ; vu : $corps"
  fi

  ports=$(curl -s --max-time 2 "$URL/api/midi/ports")
  nb=$(printf '%s' "$ports" | grep -o '"nom_client":"CoreMIDI"' | wc -l)
  if [ "$nb" -eq 2 ]; then
    ok "d : deux ports du client CoreMIDI"
  else
    echec "d : nombre de ports CoreMIDI = $nb (attendu 2) ; vu : $ports"
  fi
  nb=$(printf '%s' "$ports" | grep -o '"connecte":true' | wc -l)
  if [ "$nb" -eq 2 ]; then
    ok "d : les deux ports sont connectés"
  else
    echec "d : ports connectés = $nb (attendu 2) ; vu : $ports"
  fi
  verifie "d : assistant connecté annoncé" '"assistant":true' "$ports"

  # La note OFF met canaux_actifs à zéro après les 250 ms d'activité.
  if corps=$(attendre_motif "$URL/api/midi" '"canaux_actifs":[]' 120); then
    sleep 0.25
    corps=$(curl -s --max-time 2 "$URL/api/midi")
    if printf '%s' "$corps" | grep -qF '"canaux_actifs":[]'; then
      ok "b : note OFF, plus aucun canal actif après 250 ms"
    else
      echec "b : canal encore actif après la note OFF ; vu : $corps"
    fi
  else
    echec "b : canaux_actifs jamais vidé après la note OFF ; vu : $corps"
  fi
fi
arreter_assistant

# --- c/f. Reconnexion et Program Change -----------------------------------
debut=$(date +%s%N)
if lancer_assistant 'note:1:64:100,pause:700,pc:15:3' --attendre-client 5000; then
  if corps=$(attendre_motif "$URL/api/midi" '"canaux_actifs":[2' 40); then
    fin=$(date +%s%N)
    ms=$(( (fin - debut) / 1000000 ))
    if [ "$ms" -le 2000 ]; then
      ok "f : note reçue après relance en ${ms} ms (≤ 2 s)"
    else
      echec "f : note reçue après relance en ${ms} ms (> 2 s)"
    fi
  else
    echec "f : note non reçue après relance ; vu : $corps"
  fi

  # Program Change 0xCF → Sequencer::setStep (moteur/aeolus/engine.cpp).
  if corps=$(attendre_motif "$URL/api/orgue" '"step":3' 60); then
    ok "c : Program Change visible (étape 3 du séquenceur)"
  else
    echec "c : étape du séquenceur non changée ; vu : $corps"
  fi
fi
arreter_assistant

# --- g. Version refusée ----------------------------------------------------
arreter_serveur
rm -f "$SOCKET"
if lancer_assistant '' --refuser-version --attendre-client 10000; then
  if lancer_serveur; then
    i=0
    while [ "$i" -lt 100 ]; do
      grep -qF 'poignée refusée' "$JOURNAL_ASSISTANT" 2>/dev/null && break
      sleep 0.05
      i=$((i + 1))
    done
    verifie "g : refus de version effectivement envoyé" \
      'poignée refusée' "$(cat "$JOURNAL_ASSISTANT")"
    verifie "g : statut 1 annoncé à organum" \
      'statut envoyé 1' "$(cat "$JOURNAL_ASSISTANT")"

    code=$(curl -s -o "$TMP/orgue-g.json" -w '%{http_code}' --max-time 2 "$URL/api/orgue")
    verifie "g : organum répond encore 200" 200 "$code"
    corps=$(cat "$TMP/orgue-g.json")
    verifie "g : organum ne se croit pas dégradé" '"midi_disponible":true' "$corps"
    ports=$(curl -s --max-time 2 "$URL/api/midi/ports")
    verifie "g : aucun port après refus" '"ports":[]' "$ports"

    # Backoff de 10 s après un refus de version : en 2 s, une seule tentative.
    sleep 2
    nb=$(grep -cF 'poignée refusée' "$JOURNAL_ASSISTANT" 2>/dev/null || true)
    if [ "$nb" -eq 1 ]; then
      ok "g : aucune reconnexion en boucle (1 tentative en 2 s)"
    else
      echec "g : $nb tentatives en 2 s (attendu 1, backoff 10 s)"
    fi
    if kill -0 "$SERVEUR_PID" 2>/dev/null; then
      ok "g : le serveur ne plante pas après le refus"
    else
      echec "g : le serveur s'est arrêté après le refus de version"
    fi
    refuse "g : aucun message fatal au journal" 'panique' "$(cat "$JOURNAL")"
  fi
fi

# --- h. MIDI socket sans audio -------------------------------------------
# ORGANUM_MIDI_SOCKET + ORGANUM_SANS_BACKEND=1 : l'axe audio est dégradé,
# l'axe MIDI reste actif (cas d'un Mac sans backend audio).
arreter_assistant
arreter_serveur
rm -f "$SOCKET"
if lancer_serveur degrade; then
  corps=$(curl -s --max-time 2 "$URL/api/orgue")
  verifie "h : audio dégradé" '"audio_disponible":false' "$corps"
  verifie "h : MIDI actif malgré l'audio dégradé" \
    '"midi_disponible":true' "$corps"
  verifie "h : mode_degrade reste vrai (axe audio)" '"mode_degrade":true' "$corps"
  ports=$(curl -s --max-time 2 "$URL/api/midi/ports")
  verifie "h : ports MIDI disponibles" '"disponible":true' "$ports"
  verifie "h : backend socket annoncé" '"socket":true' "$ports"

  if lancer_assistant 'note:0:60:100,pause:2000,note:0:60:0' \
      --attendre-client 5000; then
    if corps=$(attendre_motif "$URL/api/midi" '"canaux_actifs":[1' 80); then
      ok "h : note reçue par le MIDI socket sans audio"
    else
      echec "h : note non reçue sans audio ; vu : $corps"
    fi

    # Régression observée sur macOS : sans rendu audio, g_echantillons ne
    # bougeait pas et le canal restait actif à jamais. L'échéance vaut 250 ms.
    # La sonde mesure la fenêtre d'activité en temps MURAL, de la note ON
    # observée à la disparition du canal : comparer l'horloge du moteur à
    # elle-même masquerait un diviseur TSC faux (sous XNU, la fenêtre durait
    # 849 ms au lieu de 250). La marge de 500 ms laisse le temps du sondage
    # HTTP (~50 ms) tout en attrapant un facteur 3,4.
    debut=$(date +%s%N)
    if corps=$(attendre_motif "$URL/api/midi" '"canaux_actifs":[]' 60); then
      fin=$(date +%s%N)
      ms=$(( (fin - debut) / 1000000 ))
      if [ "$ms" -le 500 ]; then
        ok "h : fenêtre d'activité vidée en ${ms} ms de temps mural (≤ 500 ms)"
      else
        echec "h : fenêtre d'activité vidée trop tard (${ms} ms > 500 ms) ; vu : $corps"
      fi
    else
      echec "h : canaux_actifs jamais vidé après la note ON ; vu : $corps"
    fi
  fi
fi

arreter_assistant
arreter_serveur

if [ "$ECHECS" -ne 0 ]; then
  echo "-- $ECHECS échec(s)"
  exit 1
fi
echo "-- MIDI socket : tous les contrôles passent"
exit 0
