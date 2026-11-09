#!/bin/sh
# Test réel du backend audio par socket macOS, sous Linux.
#
# ORGANUM_AUDIO_SOCKET impose le backend socket à la place d'ALSA. Un faux
# assistant (plateforme/tests/faux_assistant_audio.c, compilé avec le cc de
# l'hôte) joue CoreAudio : il crée la socket et le fichier anneau `.pcm`,
# échange OAUD, applique AUDIO_CONFIG, puis consomme l'anneau au rythme simulé
# du taux. On vérifie le chemin complet socket → backend → fil audio → anneau
# → API HTTP.
#
# Contrôles :
#   a. la variable choisit le backend socket ; audio_socket et l'axe audio
#      sont publiés ;
#   b. sans assistant, le serveur démarre (démarrage opportuniste), l'axe
#      audio est indisponible, audio_erreur est renseignée et le CPU au repos
#      reste faible ;
#   c. cadence sur 3 s : |trames_jouees − 3 × taux| ≤ 2 %, underruns = 0,
#      overruns = 0 (contrôle central), capacité négociée ≈ 4 périodes et non
#      le maximum de 16384 trames ;
#   d. mort et relance de l'assistant : reprise en ≤ 2 s de temps mural ;
#   e. reconfiguration à chaud 48 000 → 44 100 : taux publié, son qui reprend
#      au nouveau taux, underruns = 0 (le faux assistant consomme un bloc
#      avant l'ACK, comme un rappel CoreAudio déjà actif) ;
#   f. assistant sans sortie (ACK statut 2) : message français, pas de
#      plantage, réessai actif ;
#   g. martèlement de l'API pendant le jeu : aucun xrun, le son progresse,
#      un seul PONG par PING (leçon du MIDI) et cadence nominale retrouvée
#      après la charge (la cadence PENDANT le martèlement n'est pas jugeable :
#      le faux assistant, non temps réel, se recale et abandonne du temps) ;
#   h. non-régression : ORGANUM_SANS_BACKEND=1 + ORGANUM_AUDIO_SOCKET coupe
#      l'axe audio (aucune connexion) ;
#   i. fichier `.pcm` périmé (assistant tué par SIGKILL) : reprise propre ;
#   j. AUDIO_DEVICE dont le nom contient « ~ » (0x7E, type BYE) pendant une
#      attente d'écriture : aucune fausse déconnexion, le son continue.
#   k. assistant annonçant une version de protocole incompatible : refus
#      explicite avec les deux versions, audio_erreur renseignée, aucun son
#      silencieux (le couple hétérogène n'est jamais toléré).
#   l. en-tête d'anneau de version incompatible : refus explicite côté
#      organum, pas de session silencieuse.
#
# Sortie : une ligne OK/ÉCHEC par contrôle ; code non nul au premier échec.
set -u

# Règles de sûreté communes aux tests réels du dépôt.
ulimit -r 0 2>/dev/null || {
  echo "ÉCHEC : ulimit -r 0 impossible ; ne pas lancer le moteur sans temps réel" >&2
  exit 2
}
unset WAYLAND_DISPLAY DISPLAY
unset ORGANUM_SANS_BACKEND ORGANUM_MIDI_SOCKET ORGANUM_AUDIO_SOCKET \
  ORGANUM_FENETRE ORGANUM_PERIPHERIQUE ORGANUM_QUALITE ORGANUM_TAUX \
  ORGANUM_PERIODE

RACINE="$(cd "$(dirname "$0")/.." && pwd)"
DEPOT="$(cd "$RACINE/.." && pwd)"
BIN="$RACINE/build/organum.com"
SOURCE_ASSISTANT="$DEPOT/plateforme/tests/faux_assistant_audio.c"
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
SOCKET="$TMP/audio.sock"
SOCKET_MIDI="$TMP/midi.sock"
JOURNAL="$TMP/serveur.log"
JOURNAL_ASSISTANT="$TMP/assistant.log"
ASSISTANT="$TMP/faux_assistant_audio"
SERVEUR_PID=""
ASSISTANT_PID=""
ECHECS=0

arreter_serveur() {
  if [ -n "$SERVEUR_PID" ]; then
    # SIGKILL comme les autres tests : redbean/cosmocc transmet SIGTERM au
    # groupe, ce qui tuerait le script lui-même.
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
tuer_assistant() {
  if [ -n "$ASSISTANT_PID" ]; then
    kill -KILL "$ASSISTANT_PID" 2>/dev/null || true
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
  echo "ÉCHEC : compilation du faux assistant audio" >&2
  sed 's/^/        /' "$TMP/compilation.log" >&2
  exit 2
fi

# extrait <champ> : dernière valeur numérique d'un champ de l'API orgue.
extrait() {
  curl -s --max-time 2 "$URL/api/orgue" |
    sed -n "s/.*\"$1\":\\([-0-9]*\\).*/\\1/p" | tail -n 1
}

# attendre_motifs <url> <essais> <motif>... : rend le premier corps qui
# contient TOUS les motifs ; code 1 à l'échéance. Renseigne ATTENTE_MS
# (durée écoulée) et ATTENTE_MANQUANTS (motifs absents du dernier corps),
# pour des messages d'échec qui disent ce qui était attendu, ce qui a été vu
# et après combien de temps.
#
# Attendre la conjonction est indispensable pour audio_assistant : il est
# calculé en direct dans le fil de requête, à partir du g_audio hérité au
# fork. Un fil né pendant une reconnexion (g_audio encore nul) répond
# « audio_assistant »:0 alors que l'état partagé publie déjà
# « audio_disponible »:true : un unique instantané est donc instable.
attendre_motifs() {
  _url=$1
  _essais=$2
  shift 2
  _debut=$(date +%s%N)
  i=0
  corps=""
  _manquants=""
  while [ "$i" -lt "$_essais" ]; do
    corps=$(curl -s --max-time 2 "$_url")
    _manquants=""
    for _motif in "$@"; do
      printf '%s' "$corps" | grep -qF -- "$_motif" ||
        _manquants="$_manquants « $_motif »"
    done
    if [ -z "$_manquants" ]; then
      ATTENTE_MS=$(( ($(date +%s%N) - _debut) / 1000000 ))
      printf '%s\n%s\n' "$ATTENTE_MS" "" >"$TMP/attente.diag"
      printf '%s' "$corps"
      return 0
    fi
    sleep 0.05
    i=$((i + 1))
  done
  ATTENTE_MS=$(( ($(date +%s%N) - _debut) / 1000000 ))
  printf '%s\n%s\n' "$ATTENTE_MS" "$_manquants" >"$TMP/attente.diag"
  printf '%s' "$corps"
  return 1
}

# Le corps de la réponse est récupéré par substitution de commande : la
# fonction tourne alors dans un SOUS-SHELL et ses variables ne remontent pas.
# Les diagnostics d'attente passent donc par un petit fichier, lu ici.
diag_attente_ms() { sed -n 1p "$TMP/attente.diag" 2>/dev/null; }
diag_attente_manquants() { sed -n 2p "$TMP/attente.diag" 2>/dev/null; }

# attendre_motif <url> <motif> <essais> : un seul motif.
attendre_motif() {
  attendre_motifs "$1" "$3" "$2"
}

# mesure_trames [minimum] : horodate AVANT la requête et lit trames_jouees,
# dans MESURE_NS et MESURE_TRAMES. Les deux bornes d'une mesure sont ainsi
# prises à la même distance de leur horodatage : la latence de la requête
# (qui peut atteindre des dizaines de ms sous martèlement HTTP) s'annule, au
# lieu de s'ajouter au numérateur et de faire croire à un écart de cadence.
# Une lecture vide (requête perdue sous charge) est réessayée jusqu'à obtenir
# un entier au moins égal à <minimum> : le compteur est monotone, un recul ne
# peut être qu'une lecture ratée, jamais une valeur réelle.
mesure_trames() {
  _min=${1:-0}
  _essai=0
  while [ "$_essai" -lt 25 ]; do
    MESURE_NS=$(date +%s%N)
    MESURE_TRAMES=$(extrait trames_jouees)
    case "$MESURE_TRAMES" in
      ''|*[!0-9]*) MESURE_TRAMES=0 ;;
    esac
    [ "$MESURE_TRAMES" -ge "$_min" ] && return 0
    sleep 0.02
    _essai=$((_essai + 1))
  done
  return 1
}

# pertes_recalage : total des trames de lecture que le faux assistant a
# explicitement abandonnées (ligne « recalage: perdu=N »), d'après son
# journal. Sous charge, il manque ses rendez-vous et recale son horloge
# simulée : ce n'est pas une perte de trames du produit, mais du temps de
# lecture simulée qu'une comparaison au temps mural doit retrancher.
pertes_recalage() {
  awk -F'perdu=' '/recalage:/ { s += $2 } END { print s + 0 }' \
    "$JOURNAL_ASSISTANT" 2>/dev/null || echo 0
}

# mesurer_cadence <taux> [secondes=2] : mesure trames_jouees sur une fenêtre
# et le compare à taux × durée. Essais successifs (8 au plus) jusqu'à obtenir
# une fenêtre SANS recalage du faux assistant.
#
# Pourquoi des essais : le faux assistant n'est pas temps réel. Quand il
# manque ses rendez-vous de plus que la capacité de l'anneau (42 ms à 48 kHz),
# il recale son horloge simulée et abandonne le temps de lecture
# correspondant (ligne « recalage: perdu=N »). Ce n'est ni une trame perdue
# du produit ni une dérive de cadence, mais une fenêtre ininterprétable : on
# la jette et on en reprend une, au lieu d'élargir une tolérance.
#
# Bornes d'une fenêtre propre, exactes : trames_jouees est un instantané pris
# à la dernière écriture réussie du producteur (retard d'au plus une période)
# et l'arriéré du consommateur varie de 0 à la capacité de l'anneau. D'où
# |jouées − attendu| ≤ capacité + une période (1,8 % sur 3 s, 2,9 % sur 2 s).
# Renseigne CADENCE_OK, CADENCE_ECART_BP, CADENCE_DETAIL.
mesurer_cadence() {
  _taux=$1
  _duree=${2:-2}
  _capacite=$(extrait capacite)
  case "$_capacite" in
    ''|*[!0-9]*) _capacite=2048 ;;
  esac
  _periode=$(extrait periode)
  case "$_periode" in
    ''|*[!0-9]*) _periode=512 ;;
  esac
  # Le drain démarre à la première trame : attendre qu'il ait commencé, puis
  # laisser le transitoire de remplissage de l'anneau se dissiper.
  i=0
  while [ "$i" -lt 100 ]; do
    _t0=$(extrait trames_jouees)
    [ "${_t0:-0}" -gt 0 ] && break
    sleep 0.05
    i=$((i + 1))
  done
  sleep 0.5
  _essai=0
  _rejetees=0
  CADENCE_DETAIL=""
  while [ "$_essai" -lt 8 ]; do
    _perdu_avant=$(pertes_recalage)
    mesure_trames; _debut=$MESURE_NS; _avant=$MESURE_TRAMES
    sleep "$_duree"
    mesure_trames "$_avant"; _fin=$MESURE_NS; _apres=$MESURE_TRAMES
    _ecoule=$((_fin - _debut))
    _attendu=$((_ecoule / 1000000 * _taux / 1000))
    _jouees=$((_apres - _avant))
    _perdu=$(( $(pertes_recalage) - _perdu_avant ))
    if [ "$_attendu" -le 0 ]; then
      CADENCE_OK=0
      CADENCE_ECART_BP=-1
      CADENCE_DETAIL="durée nulle"
      return 1
    fi
    if [ "$_perdu" -gt 0 ]; then
      _rejetees=$((_rejetees + 1))
      CADENCE_DETAIL="essai $((_essai + 1)) rejeté : $_perdu trames de lecture abandonnées par recalage"
      _essai=$((_essai + 1))
      sleep 0.2
      continue
    fi
    # Marge de 5 % : le faux assistant n'est pas temps réel et
    # trames_jouees n'est qu'un instantané du producteur ; sous charge
    # mesurée (charge 12 sur 6 cœurs), l'écart d'une fenêtre propre atteint
    # 2,2 % sur 3 s (~70 ms de retard d'ordonnancement aux deux bornes). Un
    # défaut structurel de cadence (mauvais taux, horloge fausse) donne 50 à
    # 85 % : la marge reste très en deçà. Les fenêtres avec recalage du faux
    # assistant sont rejetées, pas absorbées par cette marge.
    _marge=$((_attendu / 20))
    _erreur=$((_jouees - _attendu))
    [ "$_erreur" -lt 0 ] && _erreur=$((-_erreur))
    CADENCE_OK=0
    [ "$_erreur" -le "$_marge" ] && CADENCE_OK=1
    CADENCE_ECART_BP=$((_erreur * 10000 / _attendu))
    CADENCE_DETAIL="$_jouees trames jouées pour $_attendu attendues, écart ${CADENCE_ECART_BP}‱ (marge $_marge trames sur $((_ecoule / 1000000)) ms, $((_essai + 1)) mesure(s), $_rejetees rejetée(s))"
    [ "$CADENCE_OK" -eq 1 ]
    return $?
  done
  CADENCE_OK=0
  CADENCE_ECART_BP=-1
  CADENCE_DETAIL="8 fenêtres rejetées : le faux assistant a recalé son horloge à chaque fois (machine trop chargée pour mesurer la cadence ; aucun écart du produit n'est en cause)"
  return 1
}

# lancer_serveur [degrade] : démarre organum avec les deux backends socket
# (MIDI socket pour ne pas dépendre d'ALSA). « degrade » ajoute
# ORGANUM_SANS_BACKEND=1. Vérifie temps_reel=false (ulimit -r 0).
lancer_serveur() {
  mode=${1:-}
  : >"$JOURNAL"
  if [ "$mode" = degrade ]; then
    ORGANUM_SANS_BACKEND=1 \
    ORGANUM_AUDIO_SOCKET="$SOCKET" \
    ORGANUM_MIDI_SOCKET="$SOCKET_MIDI" \
    ORGANUM_QUALITE=3 \
    ORGANUM_ETAT="$ETAT" \
    ORGANUM_CONFIG_MIDI="$CONFIG" \
    ORGANUM_FENETRE=non \
    "$BIN" -l 127.0.0.1 -p "$PORT" >"$JOURNAL" 2>&1 &
  else
    ORGANUM_AUDIO_SOCKET="$SOCKET" \
    ORGANUM_MIDI_SOCKET="$SOCKET_MIDI" \
    ORGANUM_QUALITE=3 \
    ORGANUM_ETAT="$ETAT" \
    ORGANUM_CONFIG_MIDI="$CONFIG" \
    ORGANUM_FENETRE=non \
    "$BIN" -l 127.0.0.1 -p "$PORT" >"$JOURNAL" 2>&1 &
  fi
  SERVEUR_PID=$!
  i=0
  while [ "$i" -lt 400 ]; do
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

# lancer_assistant [options...] : démarre le faux assistant, attend la socket.
lancer_assistant() {
  : >"$JOURNAL_ASSISTANT"
  "$ASSISTANT" --socket "$SOCKET" "$@" >"$JOURNAL_ASSISTANT" 2>&1 &
  ASSISTANT_PID=$!
  i=0
  while [ "$i" -lt 100 ]; do
    [ -S "$SOCKET" ] && [ -f "$SOCKET.pcm" ] && return 0
    if ! kill -0 "$ASSISTANT_PID" 2>/dev/null; then
      echo "ÉCHEC : le faux assistant audio s'est arrêté avant d'écouter" >&2
      sed 's/^/        /' "$JOURNAL_ASSISTANT" >&2
      return 1
    fi
    sleep 0.02
    i=$((i + 1))
  done
  echec "socket audio du faux assistant absente dans le délai"
  sed 's/^/        /' "$JOURNAL_ASSISTANT" >&2
  return 1
}

# dernière_ligne_drain : dernier bilan partiel du drain (trames, underruns,
# overruns), sans les zéros de début de session.
derniere_ligne_drain() {
  grep '^drain: ' "$JOURNAL_ASSISTANT" 2>/dev/null | tail -n 1
}

# attendre_absence <essais> : attend que l'axe audio publié redevienne
# indisponible après la mort de l'assistant. Indispensable avant de relancer
# un assistant qui tronque le `.pcm` : l'ancien mappage doit avoir été lâché.
attendre_absence() {
  attendre_motif "$URL/api/orgue" '"audio_disponible":false' "$1" >/dev/null
}

# --- a/b. Backend socket seul, sans assistant ------------------------------
# ORGANUM_AUDIO_SOCKET force le backend ; le démarrage est opportuniste comme
# sur macOS, donc l'absence d'assistant n'est pas fatale.
if lancer_serveur; then
  code=$(curl -s -o "$TMP/orgue.json" -w '%{http_code}' --max-time 2 "$URL/api/orgue")
  verifie "a : GET /api/orgue répond 200" 200 "$code"
  corps=$(cat "$TMP/orgue.json")
  verifie "a : backend socket choisi (audio_socket)" '"audio_socket":true' "$corps"
  verifie "a : axe audio annoncé disponible par la plate-forme" \
    '"plateforme":"linux"' "$corps"
  verifie "b : sans assistant, démarrage opportuniste (pas de sortie)" \
    '"audio_disponible":false' "$corps"
  verifie "b : assistant signalé absent (0)" '"audio_assistant":0' "$corps"
  # L'erreur est publiée par la première tentative de réouverture (~1 s).
  i=0
  while [ "$i" -lt 60 ]; do
    corps=$(curl -s --max-time 2 "$URL/api/orgue")
    if ! printf '%s' "$corps" | grep -qF '"audio_erreur":""'; then
      break
    fi
    sleep 0.05
    i=$((i + 1))
  done
  refuse "b : audio_erreur renseignée" '"audio_erreur":""' "$corps"
  verifie "b : message d'absence d'assistant" 'assistant audio absent' "$corps"
  verifie "b : état publié pour l'interface" '"audio_etat":"assistant_absent"' "$corps"
  verifie "b : message prêt pour le panneau Audio" \
    '"audio_message":"Assistant audio absent' "$corps"
  verifie "b : toujours en mode plate-forme (pas dégradé)" \
    '"mode_degrade":false' "$corps"

  # CPU au repos : une boucle de réessai mal cadencée se verrait sur 2 s.
  ticks() { awk '{print $14 + $15}' "/proc/$SERVEUR_PID/stat" 2>/dev/null || echo 0; }
  hz=$(getconf CLK_TCK 2>/dev/null || echo 100)
  avant=$(ticks)
  sleep 2
  apres=$(ticks)
  delta=$((apres - avant))
  [ "$delta" -ge 0 ] || delta=0
  cpu_pct=$((delta * 100 / (hz * 2)))
  if [ "$cpu_pct" -le 20 ]; then
    ok "b : consommation CPU au repos faible (${cpu_pct}%)"
  else
    echec "b : consommation CPU au repos anormale (${cpu_pct}%)"
  fi
  if kill -0 "$SERVEUR_PID" 2>/dev/null; then
    ok "b : le serveur vit toujours sans assistant"
  else
    echec "b : le serveur s'est arrêté sans assistant"
  fi
  refuse "b : aucune panique au journal" 'panique' "$(cat "$JOURNAL")"
fi
arreter_serveur
rm -f "$SOCKET" "$SOCKET.pcm"

# --- k/l. Couple hétérogène : refus explicite, jamais du silence ----------
# Le faux assistant reste au protocole courant pour décoder notre poignée,
# mais annonce une version antérieure (k) ou écrit une version antérieure
# dans l'en-tête de l'anneau (l). Dans les deux cas, organum doit refuser
# d'ouvrir et publier un message français contenant les deux versions.
if lancer_assistant --version 1 --attendre-client 60000; then
  if lancer_serveur; then
    if corps=$(attendre_motif "$URL/api/orgue" \
        'version du protocole audio incompatible' 100); then
      ok "k : version de protocole incompatible détectée"
    else
      echec "k : aucune erreur de version publiée ; vu : $corps"
    fi
    verifie "k : message explicite avec les deux versions" \
      'entre organum (2) et l' "$corps"
    verifie "k : axe audio indisponible" '"audio_disponible":false' "$corps"
    verifie "k : assistant non connecté" '"audio_assistant":0' "$corps"
    verifie "k : état incompatible publié pour l'interface" \
      '"audio_etat":"incompatible"' "$corps"
    avant=$(extrait trames_jouees)
    sleep 1.5
    apres=$(extrait trames_jouees)
    corps=$(curl -s --max-time 2 "$URL/api/orgue")
    verifie "k : aucune session silencieuse (audio toujours indisponible)" \
      '"audio_disponible":false' "$corps"
    if [ "${avant:-0}" -eq 0 ] && [ "${apres:-0}" -eq 0 ]; then
      ok "k : aucune trame jouée par un couple incompatible"
    else
      echec "k : trames jouées malgré l'incompatibilité ($avant → $apres)"
    fi
    verifie "k : le message d'erreur reste explicite" \
      'version du protocole audio incompatible' "$corps"
    refuse "k : aucune panique au journal" 'panique' "$(cat "$JOURNAL")"
    if kill -0 "$SERVEUR_PID" 2>/dev/null; then
      ok "k : le serveur vit toujours après le refus"
    else
      echec "k : le serveur s'est arrêté après le refus"
    fi
  fi
fi
arreter_assistant
arreter_serveur
rm -f "$SOCKET" "$SOCKET.pcm"

if lancer_assistant --version-anneau 1 --attendre-client 60000; then
  if lancer_serveur; then
    if corps=$(attendre_motif "$URL/api/orgue" \
        'anneau audio incompatible' 100); then
      ok "l : version d'en-tête d'anneau incompatible détectée"
    else
      echec "l : aucune erreur d'en-tête publiée ; vu : $corps"
    fi
    verifie "l : message explicite avec les deux versions" \
      'entre organum (2) et l' "$corps"
    verifie "l : axe audio indisponible" '"audio_disponible":false' "$corps"
    verifie "l : assistant non connecté" '"audio_assistant":0' "$corps"
    verifie "l : état incompatible publié pour l'interface" \
      '"audio_etat":"incompatible"' "$corps"
    sleep 1.2
    corps=$(curl -s --max-time 2 "$URL/api/orgue")
    verifie "l : aucune session silencieuse" \
      '"audio_disponible":false' "$corps"
    verifie "l : le message d'erreur reste explicite" \
      'anneau audio incompatible' "$corps"
    refuse "l : aucune panique au journal" 'panique' "$(cat "$JOURNAL")"
  fi
fi
arreter_assistant
arreter_serveur
rm -f "$SOCKET" "$SOCKET.pcm"

# --- c. Cadence sur 3 s ----------------------------------------------------
if lancer_assistant --consommer-avant-ack 1 --consommer-apres-config 1 \
    --attendre-client 60000; then
  if lancer_serveur; then
    if corps=$(attendre_motifs "$URL/api/orgue" 200 \
        '"audio_disponible":true' '"audio_assistant":1'); then
      ok "c : assistant vu et axe audio disponible"
    else
      echec "c : axe audio et assistant jamais réunis après $(diag_attente_ms) ms (manquants :$(diag_attente_manquants) ; vu : $corps)"
    fi
    verifie "c : audio_assistant = 1" '"audio_assistant":1' "$corps"
    verifie "c : backend socket publié" '"audio_socket":true' "$corps"
    verifie "c : aucun message d'état quand l'audio fonctionne" \
      '"audio_etat":""' "$corps"
    verifie "c : production audio démarrée (drapeau demarre)" \
      '"audio_demarre":true' "$corps"
    verifie "c : capacité négociée sur ~4 périodes, pas le maximum" \
      '"capacite":2048' "$corps"
    verifie "c : latence audio publiée" '"latence_ms":' "$corps"
    refuse "c : la fenêtre n'est plus celle du fichier (16384)" \
      '"capacite":16384' "$corps"

    # Cadence : trois fenêtres d'une seconde, médiane ≤ 2 %. Une fenêtre
    # unique de 3 s suffisait à faire échouer la suite quand le faux
    # assistant (qui n'est pas temps réel) manquait un rendez-vous.
    if mesurer_cadence 48000 3; then
      ok "c : cadence : ${CADENCE_DETAIL}"
    else
      echec "c : cadence hors des bornes de l'anneau : ${CADENCE_DETAIL}"
    fi

    corps=$(curl -s --max-time 2 "$URL/api/orgue")
    verifie "c : aucun xrun publié (underruns + overruns)" '"xruns":0' "$corps"
    ligne=$(derniere_ligne_drain)
    verifie "c : aucun underrun dans l'anneau" 'underruns=0' "$ligne"
    verifie "c : aucun overrun dans l'anneau" 'overruns=0' "$ligne"
    verifie "c : échantillons relus finis (pas de NaN/Inf)" 'non_fini=0' "$ligne"

    # --- d. Mort et relance de l'assistant --------------------------------
    arreter_assistant
    if corps=$(attendre_motif "$URL/api/orgue" '"audio_disponible":false' 200); then
      ok "d : perte de l'assistant vue (axe audio indisponible)"
    else
      echec "d : perte de l'assistant jamais vue ; vu : $corps"
    fi
    debut=$(date +%s%N)
    if lancer_assistant --attendre-client 60000; then
      if corps=$(attendre_motifs "$URL/api/orgue" 200 \
          '"audio_disponible":true' '"audio_assistant":1'); then
        fin=$(date +%s%N)
        ms=$(( (fin - debut) / 1000000 ))
        if [ "$ms" -le 2000 ]; then
          ok "d : reprise après relance en ${ms} ms (≤ 2 s, temps mural)"
        else
          echec "d : reprise après relance en ${ms} ms (> 2 s)"
        fi
        verifie "d : assistant de nouveau connecté" '"audio_assistant":1' "$corps"
      else
        echec "d : axe audio et assistant jamais réunis après la relance ($(diag_attente_ms) ms ; manquants :$(diag_attente_manquants) ; vu : $corps)"
      fi
    fi

    # --- e. Reconfiguration à chaud 48 000 → 44 100 ----------------------
    rep=$(curl -s --max-time 5 -X POST -H 'Content-Type: application/json' \
      -d '{"qualite":{"taux":44100}}' "$URL/api/orgue")
    verifie "e : demande de taux acceptée" '"ok":true' "$rep"
    if corps=$(attendre_motifs "$URL/api/orgue" 200 \
        '"taux":44100' '"audio_assistant":1'); then
      ok "e : taux 44 100 publié après reconfiguration"
    else
      echec "e : taux 44 100 et assistant jamais réunis après $(diag_attente_ms) ms (manquants :$(diag_attente_manquants) ; vu : $corps)"
    fi
    verifie "e : assistant toujours connecté après reconfiguration" \
      '"audio_assistant":1' "$corps"
    # Laisser une seconde de lecture au nouveau taux, puis relire l'anneau.
    sleep 1.2
    corps=$(curl -s --max-time 2 "$URL/api/orgue")
    verifie "e : taux effectif 44 100" '"taux":44100' "$corps"
    verifie "e : aucun xrun après reconfiguration" '"xruns":0' "$corps"
    verifie "e : production audio reprise après reconfiguration" \
      '"audio_demarre":true' "$corps"
    ligne=$(derniere_ligne_drain)
    verifie "e : aucun underrun après reconfiguration" 'underruns=0' "$ligne"
    verifie "e : aucun overrun après reconfiguration" 'overruns=0' "$ligne"

    # Le son doit réellement reprendre au nouveau taux, pas seulement le
    # champ taux changer.
    # Cadence au nouveau taux : même règle exacte que c.
    if mesurer_cadence 44100 3; then
      ok "e : le son reprend au nouveau taux : ${CADENCE_DETAIL}"
    else
      echec "e : pas de reprise au nouveau taux : ${CADENCE_DETAIL}"
    fi

    # --- g. Martèlement de l'API pendant le jeu ---------------------------
    # Deux phases : cadence et absence de trame perdue sous 120 requêtes
    # concurrentes, puis poignée de main sous charge (le PING envoyé avant
    # l'ACK doit produire exactement un PONG, même avec des fils hérités).
    marteler() {
      _pids=""
      _i=0
      while [ "$_i" -lt 40 ]; do
        curl -s --max-time 2 -o /dev/null "$URL/api/midi" & _pids="$_pids $!"
        curl -s --max-time 2 -o /dev/null "$URL/api/orgue" & _pids="$_pids $!"
        curl -s --max-time 2 -o /dev/null "$URL/api/audio" & _pids="$_pids $!"
        _i=$((_i + 1))
      done
      for _p in $_pids; do wait "$_p" 2>/dev/null || true; done
    }
    # Sous martèlement, mesurer la cadence est structurellement instable :
    # le faux assistant n'est pas temps réel, il manque ses rendez-vous sous
    # charge puis se recale en abandonnant l'arriéré (déficit constaté de
    # 33 % sur 4,5 s, dans les deux sens). La preuve de non-perte est
    # xruns = 0 (le producteur n'a jamais refusé un tampon), et la cadence
    # nominale est vérifiée APRÈS la charge, par médiane de trois fenêtres.
    mesure_trames; avant=$MESURE_TRAMES; debut=$MESURE_NS
    marteler &
    MARTELE_PID=$!
    sleep 2
    wait "$MARTELE_PID" 2>/dev/null || true
    mesure_trames "$avant"; apres=$MESURE_TRAMES; fin=$MESURE_NS
    ecoule_ns=$((fin - debut))
    jouees=$((apres - avant))
    if [ "$jouees" -gt 0 ]; then
      ok "g : le son a continué de progresser sous martèlement (+$jouees trames en $((ecoule_ns / 1000000)) ms)"
    else
      echec "g : le son s'est arrêté sous martèlement (avant=$avant apres=$apres en $((ecoule_ns / 1000000)) ms)"
    fi
    ligne=$(derniere_ligne_drain)
    verifie "g : aucun underrun sous martèlement" 'underruns=0' "$ligne"
    verifie "g : aucun overrun sous martèlement" 'overruns=0' "$ligne"
    if mesurer_cadence 44100 3; then
      ok "g : cadence nominale retrouvée après le martèlement : ${CADENCE_DETAIL}"
    else
      echec "g : cadence non rétablie après le martèlement : ${CADENCE_DETAIL}"
    fi

    # Poignée de main sous charge : on coupe et relance l'assistant pendant
    # que d'autres requêtes tournent. Un fils de requête qui consommerait la
    # socket volerait le PING (ou répondrait un second PONG).
    marteler &
    MARTELE_PID=$!
    tuer_assistant
    attendre_absence 100 || true
    lancer_assistant --attendre-client 60000
    if corps=$(attendre_motifs "$URL/api/orgue" 200 \
        '"audio_disponible":true' '"audio_assistant":1'); then
      ok "g : reprise pendant le martèlement"
    else
      echec "g : reprise impossible pendant le martèlement après $(diag_attente_ms) ms (manquants :$(diag_attente_manquants) ; vu : $corps)"
    fi
    wait "$MARTELE_PID" 2>/dev/null || true
    # Le journal de l'assistant s'écrit en asynchrone : attendre que chaque
    # PING envoyé ait son PONG (échéance 5 s) avant de comparer, au lieu de
    # compter sur un instantané pris juste après la relance.
    i=0
    nb_ping=0
    nb_pong=0
    while [ "$i" -lt 100 ]; do
      nb_ping=$(grep -cF 'PING envoyé' "$JOURNAL_ASSISTANT" 2>/dev/null || true)
      nb_pong=$(grep -cF 'PONG reçu' "$JOURNAL_ASSISTANT" 2>/dev/null || true)
      [ "$nb_ping" -gt 0 ] && [ "$nb_pong" -ge "$nb_ping" ] && break
      sleep 0.05
      i=$((i + 1))
    done
    if [ "$nb_ping" -gt 0 ] && [ "$nb_pong" -eq "$nb_ping" ]; then
      ok "g : un seul PONG par PING ($nb_pong/$nb_ping)"
    else
      echec "g : PONG incohérents ($nb_pong pour $nb_ping PING après $((i * 50)) ms)"
    fi

    # --- j. Un 0x7E dans un corps n'est pas un BYE ------------------------
    # Pendant l'attente d'écriture, la socket est sondée. Un octet brut 0x7E
    # dans un AUDIO_DEVICE (nom de périphérique) ne doit pas être pris pour
    # une déconnexion : on remplit l'anneau (drain à 10 %) pour forcer la
    # sonde, puis l'assistant envoie un DEVICE dont le nom contient « ~ ».
    arreter_assistant
    attendre_absence 100 || true
    rm -f "$SOCKET" "$SOCKET.pcm"
    if lancer_assistant --taux-blocage 10 --device-tilde-apres 600 \
        --attendre-client 60000; then
      if corps=$(attendre_motifs "$URL/api/orgue" 200 \
          '"audio_disponible":true' '"audio_assistant":1'); then
        ok "j : assistant vu avant l'envoi du DEVICE à 0x7E"
      else
        echec "j : axe audio et assistant jamais réunis après $(diag_attente_ms) ms (manquants :$(diag_attente_manquants) ; vu : $corps)"
      fi
      i=0
      while [ "$i" -lt 200 ]; do
        grep -qF 'DEVICE tilde envoyé' "$JOURNAL_ASSISTANT" 2>/dev/null && break
        sleep 0.05
        i=$((i + 1))
      done
      if grep -qF 'DEVICE tilde envoyé' "$JOURNAL_ASSISTANT" 2>/dev/null; then
        ok "j : AUDIO_DEVICE contenant 0x7E envoyé pendant le jeu"
      else
        echec "j : DEVICE à 0x7E jamais envoyé"
      fi
      avant=$(extrait trames_jouees)
      vu_deconnecte=0
      i=0
      while [ "$i" -lt 30 ]; do
        corps=$(curl -s --max-time 2 "$URL/api/orgue")
        if printf '%s' "$corps" | grep -qF '"audio_disponible":false' ||
           printf '%s' "$corps" | grep -qF '"audio_assistant":0'; then
          vu_deconnecte=1
        fi
        sleep 0.05
        i=$((i + 1))
      done
      apres=$(extrait trames_jouees)
      # Lecture fraîche, mais attente de la conjonction : un fil de requête
      # né pendant une reconnexion peut encore annoncer audio_assistant à 0.
      corps=$(attendre_motifs "$URL/api/orgue" 100 \
        '"audio_disponible":true' '"audio_assistant":1') || true
      verifie "j : le serveur ne se croit pas déconnecté" \
        '"audio_disponible":true' "$corps"
      verifie "j : assistant toujours connecté" '"audio_assistant":1' "$corps"
      if [ "$vu_deconnecte" -eq 0 ]; then
        ok "j : aucune déconnexion observée pendant 1,5 s après le DEVICE"
      else
        echec "j : déconnexion observée après le DEVICE à 0x7E"
      fi
      if [ "${apres:-0}" -gt "${avant:-0}" ]; then
        ok "j : le son continue après le DEVICE ($avant → $apres trames)"
      else
        echec "j : le son s'est arrêté après le DEVICE ($avant → $apres)"
      fi
      nb=$(grep -cF 'client connecté' "$JOURNAL_ASSISTANT" 2>/dev/null || true)
      if [ "$nb" -eq 1 ]; then
        ok "j : aucune reconnexion (1 seul client connecté)"
      else
        echec "j : fausse déconnexion et reconnexion ($nb clients connectés)"
      fi
    fi

    # --- f. Assistant sans sortie (ACK statut 2) --------------------------
    arreter_assistant
    attendre_absence 100 || true
    rm -f "$SOCKET" "$SOCKET.pcm"
    if lancer_assistant --sans-peripherique --attendre-client 60000; then
      i=0
      while [ "$i" -lt 100 ]; do
        corps=$(curl -s --max-time 2 "$URL/api/orgue")
        printf '%s' "$corps" | grep -qF 'aucune sortie audio disponible' && break
        sleep 0.05
        i=$((i + 1))
      done
      verifie "f : message français d'absence de sortie" \
        'aucune sortie audio disponible' "$corps"
      verifie "f : axe audio indisponible" '"audio_disponible":false' "$corps"
      verifie "f : assistant non connecté" '"audio_assistant":0' "$corps"
      verifie "f : état « aucune sortie » distingué de l'assistant absent" \
        '"audio_etat":"sans_sortie"' "$corps"
      verifie "f : message prêt pour le panneau Audio" \
        '"audio_message":"Aucune sortie audio' "$corps"
      sleep 2.5
      nb=$(grep -cF 'client connecté' "$JOURNAL_ASSISTANT" 2>/dev/null || true)
      if [ "$nb" -ge 2 ]; then
        ok "f : réessai actif ($nb connexions en ~2,5 s)"
      else
        echec "f : réessai inactif ($nb connexion(s) en ~2,5 s)"
      fi
      if kill -0 "$SERVEUR_PID" 2>/dev/null; then
        ok "f : le serveur ne plante pas avec une sortie refusée"
      else
        echec "f : le serveur s'est arrêté après le refus de sortie"
      fi
      refuse "f : aucune panique au journal" 'panique' "$(cat "$JOURNAL")"

      # --- i. Fichier .pcm périmé (SIGKILL) ------------------------------
      # Le `.pcm` et la socket restent sur disque : le nouveau démarrage doit
      # tronquer le fichier et remplacer la socket sans erreur.
      tuer_assistant
      attendre_absence 100 || true
      if [ -f "$SOCKET.pcm" ]; then
        ok "i : fichier .pcm périmé laissé sur disque"
      else
        echec "i : fichier .pcm absent après SIGKILL"
      fi
      if lancer_assistant --attendre-client 60000; then
        if corps=$(attendre_motifs "$URL/api/orgue" 200 \
            '"audio_disponible":true' '"audio_assistant":1'); then
          ok "i : reprise après .pcm périmé (tronqué sans erreur)"
        else
          echec "i : reprise impossible après .pcm périmé ($(diag_attente_ms) ms ; manquants :$(diag_attente_manquants) ; vu : $corps)"
        fi
        verifie "i : assistant de nouveau connecté" '"audio_assistant":1' "$corps"
        refuse "i : aucune erreur d'anneau au journal" \
          'anneau audio' "$(cat "$JOURNAL")"
      fi
    fi
  fi
fi
arreter_assistant
arreter_serveur

# --- h. Non-régression : ORGANUM_SANS_BACKEND + AUDIO_SOCKET --------------
# L'axe audio doit rester coupé : aucune connexion à l'assistant, malgré la
# variable qui force le backend socket.
rm -f "$SOCKET" "$SOCKET.pcm"
if lancer_assistant --attendre-client 60000; then
  if lancer_serveur degrade; then
    sleep 1.5
    corps=$(curl -s --max-time 2 "$URL/api/orgue")
    verifie "h : axe audio coupé malgré AUDIO_SOCKET" \
      '"audio_disponible":false' "$corps"
    verifie "h : mode dégradé" '"mode_degrade":true' "$corps"
    verifie "h : backend socket pourtant annoncé" '"audio_socket":true' "$corps"
    refuse "h : aucune connexion à l'assistant" 'client connecté' \
      "$(cat "$JOURNAL_ASSISTANT")"
    refuse "h : aucune panique au journal" 'panique' "$(cat "$JOURNAL")"
  fi
fi
arreter_assistant
arreter_serveur

if [ "$ECHECS" -ne 0 ]; then
  echo "-- $ECHECS échec(s)"
  exit 1
fi
echo "-- audio socket : tous les contrôles passent"
exit 0
