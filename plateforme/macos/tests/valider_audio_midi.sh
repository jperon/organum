#!/bin/sh
# Validation RÉELLE de CoreAudio et de CoreMIDI sur macOS, sans clavier ni
# carte son physique : c'est le contrôle de la CI Apple Silicon, où l'on ne
# peut pas brancher de matériel.
#
# Le runner macos-latest fournit un périphérique de sortie virtuel Apple
# (« Apple Virtual Sound Device », 2 canaux, 48 kHz) : le chemin complet
# organum → assistant → anneau partagé → rappel CoreAudio est donc
# exerçable. CoreMIDI accepte, lui, une source virtuelle, ce qui permet
# d'injecter une note sans clavier.
#
# Un seul serveur porte les deux axes (ce sont deux domaines indépendants de
# l'assistant) :
#   a. l'assistant embarqué démarre, CoreAudio s'ouvre :
#      audio_disponible, audio_assistant = 1, latence_ms > 0, audio_demarre ;
#   b. cadence : trois fenêtres de 5 s après 1 s de stabilisation, médiane
#      ≤ 2 % de taux, et aucun NOUVEL xrun pendant ces fenêtres (preuve que
#      le rappel CoreAudio consomme l'anneau au bon rythme, sans confondre
#      un pic de charge isolé avec un défaut structurel) ;
#   c. MIDI de bout en bout : une source virtuelle CoreMIDI joue une note,
#      /api/midi publie canaux_actifs non vide, puis revient à vide quand
#      l'émetteur relâche la note ;
#   d. le serveur vit toujours à la fin.
#
# La compilation des deux auxiliaires C se fait avec le clang de l'hôte.
# Usage : valider_audio_midi.sh <chemin d'organum.com>
# Sortie : une ligne OK/ÉCHEC par contrôle ; code non nul si un contrôle
# échoue.
set -u

BIN=${1:-}
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
  echo "ÉCHEC : organum.com absent ou non exécutable : « ${BIN:-} »" >&2
  exit 2
fi
ICI=$(cd "$(dirname "$0")" && pwd)
PORT=18100
URL="http://127.0.0.1:$PORT"

# Ne jamais hériter d'un mode dégradé ni d'un forçage de backend : ce test
# doit emprunter le chemin réel macOS (assistant embarqué, socket).
unset ORGANUM_SANS_BACKEND ORGANUM_PERIPHERIQUE ORGANUM_AUDIO_SOCKET \
  ORGANUM_MIDI_SOCKET ORGANUM_TAUX ORGANUM_PERIODE ORGANUM_LIMITEUR

TMP=$(mktemp -d) || exit 2
EMETTEUR_LOG="$TMP/emetteur.log"
JOURNAL="$TMP/serveur.log"
ORQUE="$TMP/orgue.json"
MIDIJSON="$TMP/midi.json"
EMETTEUR_BIN="$TMP/emetteur_midi"

PID=
EMETTEUR_PID=
ASSISTANT_PID=
echecs=0

ok() { echo "OK : $*"; }
echec() {
  echo "ÉCHEC : $*"
  echecs=$((echecs + 1))
}

# champ <fichier> <nom> : valeur JSON scalaire (nombre, booléen, chaîne).
champ() {
  grep -o "\"$2\":[^,}]*" "$1" 2>/dev/null | head -n 1 | cut -d: -f2- |
    tr -d ' "' || true
}

# maintenant_ns : horloge monotone en nanosecondes (perl est fourni par macOS).
# CLOCK_MONOTONIC évite qu'un saut NTP fausse une durée ; si le perl de
# l'hôte ne l'expose pas, on retombe sur l'horloge murale.
maintenant_ns() {
  perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC -e \
    'printf "%.0f\n", clock_gettime(CLOCK_MONOTONIC) * 1000000000' 2>/dev/null ||
    perl -MTime::HiRes=time -e 'printf "%.0f\n", time * 1000000000'
}

# Règles pures de la mesure, testées localement par tester_cadence.sh.
. "$ICI/cadence.sh"
CADENCE_TOLERANCE_BP=200

# arreter_serveur : SIGKILL, jamais SIGTERM : redbean enverrait SIGTERM à
# tout son groupe, y compris l'agent du runner (voir AGENTS.md).
arreter_serveur() {
  if [ -n "${PID:-}" ]; then
    kill -KILL "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
    PID=
  fi
  if [ -n "${ASSISTANT_PID:-}" ] && [ "$ASSISTANT_PID" != 0 ]; then
    kill -KILL "$ASSISTANT_PID" 2>/dev/null || true
    ASSISTANT_PID=
  fi
}

arreter_emetteur() {
  if [ -n "${EMETTEUR_PID:-}" ]; then
    kill -TERM "$EMETTEUR_PID" 2>/dev/null || true
    wait "$EMETTEUR_PID" 2>/dev/null || true
    EMETTEUR_PID=
  fi
}

nettoyer() {
  arreter_emetteur
  arreter_serveur
  rm -rf "$TMP"
}
trap nettoyer EXIT INT TERM

# attendre <motif> <essais> : attend un motif dans /api/orgue (0,25 s/essai).
attendre() {
  i=0
  while [ "$i" -lt "$2" ]; do
    if curl -fsS --connect-timeout 1 --max-time 2 "$URL/api/orgue" \
        > "$ORQUE" 2>/dev/null && grep -q "$1" "$ORQUE"; then
      return 0
    fi
    i=$((i + 1))
    sleep 0.25
  done
  return 1
}

verifie() { # verifie <motif> <fichier> <description>
  if grep -q "$1" "$2" 2>/dev/null; then
    ok "$3"
  else
    echec "$3 (motif « $1 » absent)"
  fi
}

# --- Auxiliaires C --------------------------------------------------------
if ! clang -O2 -Wall -Wextra -framework CoreMIDI -framework CoreFoundation \
    "$ICI/emetteur_midi.c" -o "$EMETTEUR_BIN" > "$TMP/clang.log" 2>&1; then
  echo "ÉCHEC : compilation de l'émetteur MIDI impossible" >&2
  sed 's/^/        /' "$TMP/clang.log" >&2
  exit 2
fi

# --- Émetteur MIDI avant le serveur, pour que l'assistant le voie naître ---
"$EMETTEUR_BIN" organum-test-ci > "$EMETTEUR_LOG" 2>&1 &
EMETTEUR_PID=$!
i=0
while [ "$i" -lt 40 ]; do
  grep -q 'prêt' "$EMETTEUR_LOG" 2>/dev/null && break
  kill -0 "$EMETTEUR_PID" 2>/dev/null || break
  i=$((i + 1))
  sleep 0.1
done
if grep -q 'prêt' "$EMETTEUR_LOG" 2>/dev/null; then
  ok "a : source MIDI virtuelle créée ($(cat "$EMETTEUR_LOG"))"
else
  echec "a : la source MIDI virtuelle n'a pas été créée"
  sed 's/^/        /' "$EMETTEUR_LOG" >&2
fi

# --- Serveur réel : ni ORGANUM_SANS_BACKEND, ni sortie muette -------------
ORGANUM_ETAT="$TMP/etat.json" \
ORGANUM_CONFIG_MIDI="$TMP/midi.json" \
ORGANUM_FENETRE=non \
ORGANUM_QUALITE=3 \
"$BIN" -l 127.0.0.1 -p "$PORT" > "$JOURNAL" 2>&1 &
PID=$!

i=0
pret=0
while [ "$i" -lt 240 ]; do
  if curl -fsS --connect-timeout 1 --max-time 2 "$URL/api/orgue" \
      > "$ORQUE" 2>/dev/null; then
    pret=1
    break
  fi
  if ! kill -0 "$PID" 2>/dev/null; then
    break
  fi
  i=$((i + 1))
  sleep 0.25
done
if [ "$pret" != 1 ]; then
  echec "a : organum ne répond pas sur $URL"
  echo "---- journal organum ----" >&2
  sed 's/^/        /' "$JOURNAL" >&2
  exit 1
fi
verifie '"plateforme":"macos"' "$ORQUE" "a : plate-forme macOS publiée"

# --- a. Audio réel --------------------------------------------------------
if attendre '"audio_disponible":true' 240; then
  ok "a : CoreAudio ouvert, axe audio disponible"
else
  echec "a : axe audio jamais disponible (ni périphérique, ni assistant ?)"
  sed 's/^/        /' "$JOURNAL" >&2
fi
# audio_disponible (copie partagée du fil audio) et audio_assistant (calculé
# dans le fil de requête à partir du g_audio hérité au fork) ne sont pas
# publiés dans le même instantané : un fil né juste avant la connexion répond
# encore 0. Même leçon que le contrôle d de test-audio-socket.sh : attendre
# la conjonction, jamais une lecture unique.
if attendre '"audio_assistant":1' 40; then
  ok "a : assistant audio connecté (audio_assistant = 1)"
else
  echec "a : audio_assistant jamais passé à 1 (après 10 s)"
fi
# La production démarre au premier rappel CoreAudio, et latence_ms vient du
# DEVICE envoyé par l'assistant : les attendre avant de conclure.
if attendre '"audio_demarre":true' 40; then
  ok "a : production audio démarrée"
else
  echec "a : audio_demarre jamais vrai (après 10 s)"
fi
verifie '"audio_socket":true' "$ORQUE" "a : backend socket (assistant) choisi"
verifie '"midi_disponible":true' "$ORQUE" "a : axe MIDI disponible"

i=0
latence=0
while [ "$i" -lt 40 ]; do
  latence=$(champ "$ORQUE" latence_ms)
  [ -n "$latence" ] || latence=0
  awk -v l="$latence" 'BEGIN { exit !(l + 0 > 0) }' && break
  i=$((i + 1))
  sleep 0.25
  curl -fsS --max-time 2 "$URL/api/orgue" > "$ORQUE" 2>/dev/null || true
done
taux=$(champ "$ORQUE" taux)
[ -n "$taux" ] || taux=0
if awk -v l="$latence" 'BEGIN { exit !(l + 0 > 0) }'; then
  ok "a : latence audio publiée (${latence} ms, taux ${taux} Hz)"
else
  echec "a : latence_ms absente ou nulle après $((i * 250)) ms (${latence})"
fi
if [ "$taux" -gt 0 ] 2>/dev/null; then
  ok "a : taux effectif ${taux} Hz"
else
  echec "a : taux effectif invalide (${taux})"
  taux=48000
fi

# --- b. Cadence : trois fenêtres de 5 s, médiane -------------------------
# Le drain doit avoir commencé, puis on laisse 1 s de stabilisation : au
# démarrage l'anneau se remplit et les premiers rappels CoreAudio peuvent
# être irréguliers. Mesurer dès la première trame, sur 3 s, confondait ce
# transitoire (et un pic de charge de ~70 ms) avec un défaut de cadence :
# 2,36 % observé sur un runner partagé, contre 2 % de tolérance.
i=0
while [ "$i" -lt 80 ]; do
  [ "$(champ "$ORQUE" trames_jouees)" -gt 0 ] 2>/dev/null && break
  curl -fsS --max-time 2 "$URL/api/orgue" > "$ORQUE" 2>/dev/null || true
  i=$((i + 1))
  sleep 0.1
done
sleep 1
# Référence des xruns après stabilisation : un underrun au tout premier
# rappel (l'anneau se remplit) est un transitoire de démarrage, pas un défaut
# de la lecture mesurée. On exige donc qu'aucun NOUVEL xrun n'apparaisse
# pendant les trois fenêtres, et on publie les deux valeurs pour la trace.
curl -fsS --max-time 2 "$URL/api/orgue" > "$ORQUE" 2>/dev/null || true
xruns_avant=$(champ "$ORQUE" xruns)
xruns_recents_avant=$(champ "$ORQUE" xruns_recents)
if [ -z "$xruns_avant" ] || [ -z "$xruns_recents_avant" ]; then
  echec "b : compteurs xruns non publiés dans /api/orgue"
fi
[ -n "$xruns_avant" ] || xruns_avant=0
[ -n "$xruns_recents_avant" ] || xruns_recents_avant=0

# Trois fenêtres de 5 s, médiane : une préemption isolée peut fausser une
# fenêtre, pas les trois. Un défaut structurel (facteur 1,5, horloge fausse)
# fausse en revanche toutes les fenêtres et reste détecté très au-delà de 2 %.
mesures=
m=0
while [ "$m" -lt 3 ]; do
  # Horodatage AVANT chaque requête : les deux lectures de trames_jouees
  # sont alors faites à la même distance de leur horodatage, et la latence
  # locale de la requête s'annule. (Un instantané frais avant la mesure,
  # mais horodaté après, laissait un biais résiduel de quelques ms.)
  debut=$(maintenant_ns)
  curl -fsS --max-time 2 "$URL/api/orgue" > "$ORQUE" 2>/dev/null || true
  avant=$(champ "$ORQUE" trames_jouees)
  [ -n "$avant" ] || avant=0
  sleep 5
  fin=$(maintenant_ns)
  curl -fsS --max-time 2 "$URL/api/orgue" > "$ORQUE" 2>/dev/null || true
  apres=$(champ "$ORQUE" trames_jouees)
  [ -n "$apres" ] || apres=0
  jouees=$((apres - avant))
  attendu=$(awk -v e="$((fin - debut))" -v t="$taux" \
    'BEGIN { printf "%.0f", e / 1000000000 * t }')
  pct=$(cadence_ecart_bp "$jouees" "$attendu")
  if [ "$pct" -lt 0 ]; then
    echec "b : mesure de cadence impossible (durée nulle, fenêtre $((m + 1)))"
    break
  fi
  echo "b : fenêtre $((m + 1))/3 sur 5 s : $jouees trames pour $attendu attendues (${pct}‱ d'écart)"
  mesures="$mesures $pct"
  m=$((m + 1))
done
if [ "$m" -eq 3 ]; then
  # shellcheck disable=SC2086
  set -- $mesures
  mediane=$(cadence_mediane "$1" "$2" "$3")
  if [ "$mediane" -le "$CADENCE_TOLERANCE_BP" ]; then
    ok "b : cadence médiane : ${mediane}‱ d'écart sur 3 fenêtres de 5 s (≤ 2 %)"
  else
    echec "b : cadence hors tolérance : médiane ${mediane}‱ > 2 % sur 3 fenêtres de 5 s"
  fi
fi
xruns_apres=$(champ "$ORQUE" xruns)
xruns_recents_apres=$(champ "$ORQUE" xruns_recents)
if [ -z "$xruns_apres" ] || [ -z "$xruns_recents_apres" ]; then
  echec "b : compteurs xruns non publiés à la fin de la mesure"
fi
[ -n "$xruns_apres" ] || xruns_apres=0
[ -n "$xruns_recents_apres" ] || xruns_recents_apres=0
if [ "$xruns_apres" -eq "$xruns_avant" ] 2>/dev/null; then
  ok "b : aucun nouvel xrun (underrun/overrun) pendant la mesure ($xruns_apres, référence $xruns_avant)"
else
  echec "b : $((xruns_apres - xruns_avant)) nouvel(x) xrun(s) pendant la mesure ($xruns_avant → $xruns_apres)"
fi
if [ "$xruns_recents_apres" -le "$xruns_recents_avant" ] 2>/dev/null; then
  ok "b : aucun xrun récent nouveau ($xruns_recents_apres, référence $xruns_recents_avant)"
else
  echec "b : xruns récents en hausse ($xruns_recents_avant → $xruns_recents_apres)"
fi

ASSISTANT_PID=$(champ "$ORQUE" assistant_pid)
[ -n "$ASSISTANT_PID" ] || ASSISTANT_PID=0

# --- c. MIDI de bout en bout ---------------------------------------------
i=0
actif=0
while [ "$i" -lt 120 ]; do
  if curl -fsS --max-time 2 "$URL/api/midi" > "$MIDIJSON" 2>/dev/null &&
      grep -qE '"canaux_actifs":\[[0-9]' "$MIDIJSON"; then
    actif=1
    break
  fi
  i=$((i + 1))
  sleep 0.25
done
if [ "$actif" = 1 ]; then
  ok "c : note CoreMIDI reçue, canaux_actifs non vide ($(champ "$MIDIJSON" canaux_actifs))"
else
  echec "c : aucune activité MIDI vue dans /api/midi"
  echo "        /api/midi : $(cat "$MIDIJSON" 2>/dev/null)" >&2
  echo "        --- journal de l'assistant ---" >&2
  JOURNAL_AIDE=$(champ "$ORQUE" assistant_log)
  if [ -n "$JOURNAL_AIDE" ] && [ -f "$JOURNAL_AIDE" ]; then
    sed 's/^/        /' "$JOURNAL_AIDE" | tail -n 30 >&2
  fi
  sed 's/^/        /' "$EMETTEUR_LOG" >&2
fi

arreter_emetteur
i=0
retombe=0
while [ "$i" -lt 40 ]; do
  if curl -fsS --max-time 2 "$URL/api/midi" > "$MIDIJSON" 2>/dev/null &&
      grep -q '"canaux_actifs":\[\]' "$MIDIJSON"; then
    retombe=1
    break
  fi
  i=$((i + 1))
  sleep 0.1
done
if [ "$retombe" = 1 ]; then
  ok "c : relâchement vu, canaux_actifs revenu à vide"
else
  echec "c : canaux_actifs ne revient pas à vide après le relâchement"
fi

# --- d. Le serveur a survécu aux deux axes -------------------------------
if curl -fsS --max-time 2 "$URL/api/orgue" > "$ORQUE" 2>/dev/null; then
  ok "d : le serveur vit toujours après les contrôles audio et MIDI"
else
  echec "d : le serveur ne répond plus à la fin"
fi

if [ "$echecs" -ne 0 ]; then
  echo "ÉCHEC : $echecs contrôle(s) en échec" >&2
  echo "---- journal organum ----" >&2
  sed 's/^/        /' "$JOURNAL" >&2
  exit 1
fi
echo "validation audio réelle et MIDI de bout en bout : OK"
