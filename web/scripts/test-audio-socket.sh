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
#      overruns = 0 (contrôle central) ;
#   d. mort et relance de l'assistant : reprise en ≤ 2 s de temps mural ;
#   e. reconfiguration à chaud 48 000 → 44 100 : taux publié, underruns = 0 ;
#   f. assistant sans sortie (ACK statut 2) : message français, pas de
#      plantage, réessai actif ;
#   g. martèlement de l'API pendant le jeu : aucune trame perdue et un seul
#      PONG par PING (leçon du MIDI) ;
#   h. non-régression : ORGANUM_SANS_BACKEND=1 + ORGANUM_AUDIO_SOCKET coupe
#      l'axe audio (aucune connexion) ;
#   i. fichier `.pcm` périmé (assistant tué par SIGKILL) : reprise propre ;
#   j. AUDIO_DEVICE dont le nom contient « ~ » (0x7E, type BYE) pendant une
#      attente d'écriture : aucune fausse déconnexion, le son continue.
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

# --- c. Cadence sur 3 s ----------------------------------------------------
if lancer_assistant --attendre-client 15000; then
  if lancer_serveur; then
    if corps=$(attendre_motif "$URL/api/orgue" '"audio_disponible":true' 100); then
      ok "c : assistant vu et axe audio disponible"
    else
      echec "c : axe audio jamais disponible ; vu : $corps"
    fi
    verifie "c : audio_assistant = 1" '"audio_assistant":1' "$corps"
    verifie "c : backend socket publié" '"audio_socket":true' "$corps"
    verifie "c : aucun message d'état quand l'audio fonctionne" \
      '"audio_etat":""' "$corps"

    # Le drain démarre à la première trame ; attendre qu'il ait commencé.
    i=0
    while [ "$i" -lt 100 ]; do
      t0=$(extrait trames_jouees)
      [ "${t0:-0}" -gt 0 ] && break
      sleep 0.05
      i=$((i + 1))
    done

    debut=$(date +%s%N)
    avant=$(extrait trames_jouees)
    sleep 3
    fin=$(date +%s%N)
    apres=$(extrait trames_jouees)
    ecoule_ns=$((fin - debut))
    attendu=$((ecoule_ns / 1000000 * 48))
    jouees=$((apres - avant))
    if [ "$attendu" -le 0 ]; then
      echec "c : mesure de cadence impossible (durée nulle)"
    else
      erreur=$((jouees - attendu))
      [ "$erreur" -lt 0 ] && erreur=$((-erreur))
      # 2 % = 200 centièmes de pour cent (points de base).
      pct=$((erreur * 10000 / attendu))
      if [ "$pct" -le 200 ]; then
        ok "c : cadence sur ${ecoule_ns} ns : $jouees trames pour $attendu attendues (${pct}‱ d'écart, ≤ 2 %)"
      else
        echec "c : cadence hors tolérance : $jouees trames pour $attendu attendues (${pct}‱ d'écart > 2 %)"
      fi
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
    if lancer_assistant --attendre-client 15000; then
      if corps=$(attendre_motif "$URL/api/orgue" '"audio_disponible":true' 100); then
        fin=$(date +%s%N)
        ms=$(( (fin - debut) / 1000000 ))
        if [ "$ms" -le 2000 ]; then
          ok "d : reprise après relance en ${ms} ms (≤ 2 s, temps mural)"
        else
          echec "d : reprise après relance en ${ms} ms (> 2 s)"
        fi
        verifie "d : assistant de nouveau connecté" '"audio_assistant":1' "$corps"
      else
        echec "d : axe audio jamais rétabli après la relance ; vu : $corps"
      fi
    fi

    # --- e. Reconfiguration à chaud 48 000 → 44 100 ----------------------
    rep=$(curl -s --max-time 5 -X POST -H 'Content-Type: application/json' \
      -d '{"qualite":{"taux":44100}}' "$URL/api/orgue")
    verifie "e : demande de taux acceptée" '"ok":true' "$rep"
    if corps=$(attendre_motif "$URL/api/orgue" '"taux":44100' 200); then
      ok "e : taux 44 100 publié après reconfiguration"
    else
      echec "e : taux 44 100 jamais publié ; vu : $corps"
    fi
    verifie "e : assistant toujours connecté après reconfiguration" \
      '"audio_assistant":1' "$corps"
    # Laisser une seconde de lecture au nouveau taux, puis relire l'anneau.
    sleep 1.2
    corps=$(curl -s --max-time 2 "$URL/api/orgue")
    verifie "e : taux effectif 44 100" '"taux":44100' "$corps"
    verifie "e : aucun xrun après reconfiguration" '"xruns":0' "$corps"
    ligne=$(derniere_ligne_drain)
    verifie "e : aucun underrun après reconfiguration" 'underruns=0' "$ligne"
    verifie "e : aucun overrun après reconfiguration" 'overruns=0' "$ligne"

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
    avant=$(extrait trames_jouees)
    debut=$(date +%s%N)
    marteler &
    MARTELE_PID=$!
    sleep 2
    wait "$MARTELE_PID" 2>/dev/null || true
    fin=$(date +%s%N)
    apres=$(extrait trames_jouees)
    ecoule_ns=$((fin - debut))
    attendu=$((ecoule_ns / 1000000 * 44))
    jouees=$((apres - avant))
    erreur=$((jouees - attendu))
    [ "$erreur" -lt 0 ] && erreur=$((-erreur))
    # La cadence est approximative sous charge (le drain peut rattraper son
    # retard après une gigue) : la preuve de non-perte reste xruns = 0, et la
    # borne de 10 % attrape une dérive franche.
    if [ "$attendu" -gt 0 ] && [ $((erreur * 100)) -le $((attendu * 10)) ]; then
      ok "g : aucune trame perdue sous martèlement ($jouees trames pour $attendu attendues, ≤ 10 %)"
    else
      echec "g : trames perdues sous martèlement ($jouees pour $attendu attendues ; avant=$avant apres=$apres ecoule=$ecoule_ns)"
    fi
    ligne=$(derniere_ligne_drain)
    verifie "g : aucun underrun sous martèlement" 'underruns=0' "$ligne"
    verifie "g : aucun overrun sous martèlement" 'overruns=0' "$ligne"

    # Poignée de main sous charge : on coupe et relance l'assistant pendant
    # que d'autres requêtes tournent. Un fils de requête qui consommerait la
    # socket volerait le PING (ou répondrait un second PONG).
    marteler &
    MARTELE_PID=$!
    tuer_assistant
    attendre_absence 100 || true
    lancer_assistant --attendre-client 15000
    if corps=$(attendre_motif "$URL/api/orgue" '"audio_disponible":true' 200); then
      ok "g : reprise pendant le martèlement"
    else
      echec "g : reprise impossible pendant le martèlement ; vu : $corps"
    fi
    wait "$MARTELE_PID" 2>/dev/null || true
    nb_ping=$(grep -cF 'PING envoyé' "$JOURNAL_ASSISTANT" 2>/dev/null || true)
    nb_pong=$(grep -cF 'PONG reçu' "$JOURNAL_ASSISTANT" 2>/dev/null || true)
    if [ "$nb_ping" -gt 0 ] && [ "$nb_pong" -eq "$nb_ping" ]; then
      ok "g : un seul PONG par PING ($nb_pong/$nb_ping)"
    else
      echec "g : PONG incohérents ($nb_pong pour $nb_ping PING)"
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
        --attendre-client 15000; then
      if corps=$(attendre_motif "$URL/api/orgue" '"audio_disponible":true' 200); then
        ok "j : assistant vu avant l'envoi du DEVICE à 0x7E"
      else
        echec "j : axe audio jamais disponible ; vu : $corps"
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
      corps=$(curl -s --max-time 2 "$URL/api/orgue")
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
    if lancer_assistant --sans-peripherique --attendre-client 15000; then
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
      if lancer_assistant --attendre-client 15000; then
        if corps=$(attendre_motif "$URL/api/orgue" '"audio_disponible":true' 200); then
          ok "i : reprise après .pcm périmé (tronqué sans erreur)"
        else
          echec "i : reprise impossible après .pcm périmé ; vu : $corps"
        fi
        corps=$(curl -s --max-time 2 "$URL/api/orgue")
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
if lancer_assistant --attendre-client 4000; then
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
