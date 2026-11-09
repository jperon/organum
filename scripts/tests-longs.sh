#!/bin/sh
# Tests longs : API des réglages (serveur réel sur sortie muette), bancs du
# moteur hors de la suite rapide, et couche plate-forme sans carte son.
#
#   scripts/tests-longs.sh
#
# Les bancs qui ne se compilent plus (ou dont les sources ont disparu) sont
# signalés IGNORÉ avec leur raison : ils ne comptent jamais comme un succès.
# Code 0 si aucun ÉCHEC ; les IGNORÉ ne font pas échouer la suite.
set -u

# Sûreté : jamais de temps réel (la sortie null rendrait le fil audio à 100 %
# d'un cœur et affamerait les interruptions), jamais d'affichage hérité.
ulimit -r 0 2>/dev/null || {
  echo "ÉCHEC : ulimit -r 0 impossible ; ne pas lancer le moteur sans temps réel" >&2
  exit 2
}
unset WAYLAND_DISPLAY DISPLAY

RACINE="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)" || exit 2
mkdir -p "$TMP/journaux" "$TMP/bin"
ECHECS=0
IGNORES=0
OKS=0
TOTAL_NS=0
DEBUT_NS=$(date +%s%N)

arreter_serveurs() {
  # Aucun serveur n'est lancé directement ici : test-qualite.sh arrête le sien
  # par PID. Ce crochet ne tue donc rien par nom de processus.
  :
}

nettoyer() {
  arreter_serveurs
  rm -rf "$TMP"
}

trap nettoyer EXIT
trap 'nettoyer; exit 130' INT TERM

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

# Nom de journal sûr (sans espaces ni ponctuation).
nom_journal() {
  printf '%s' "$1" | tr ' /:()' '_____' | tr -cd 'A-Za-z0-9_.-'
}

# duree <début_ns> <fin_ns> : durée lisible en secondes.
duree() {
  printf '%s.%03d s' "$(( ($2 - $1) / 1000000000 ))" "$(( (($2 - $1) / 1000000) % 1000 ))"
}

# executer <nom> <commande...> : horodate, journalise et compte.
executer() {
  nom=$1
  shift
  journal="$TMP/journaux/$(nom_journal "$nom").log"
  debut=$(date +%s%N)
  if "$@" >"$journal" 2>&1; then
    fin=$(date +%s%N)
    TOTAL_NS=$((TOTAL_NS + fin - debut))
    ok "$nom ($(duree "$debut" "$fin"))"
  else
    fin=$(date +%s%N)
    TOTAL_NS=$((TOTAL_NS + fin - debut))
    echo "---- sortie de $nom ----"
    sed 's/^/        /' "$journal"
    echo "------------------------"
    echec "$nom ($(duree "$debut" "$fin"))"
  fi
}

# compiler_banc <source> <binaire> : compilation x86-64 seule contre
# libaeolus.a, comme le documente moteur/tests/compiler-test-x86.sh.
compiler_banc() {
  source=$1
  binaire=$2
  sh "$RACINE/moteur/tests/compiler-test-x86.sh" \
    "$RACINE/moteur" "$binaire" "$source"
}

# banc <nom> <source.cpp> [arguments...] : compilation puis exécution.
banc() {
  nom=$1
  source=$2
  shift 2
  binaire="$TMP/bin/$(nom_journal "$nom")"
  journal="$TMP/journaux/$(nom_journal "$nom").compilation.log"
  if ! compiler_banc "tests/$source" "$binaire" >"$journal" 2>&1; then
    echo "---- sortie de compilation de $nom ----"
    sed 's/^/        /' "$journal"
    echo "--------------------------------------"
    ignore "$nom (ne se compile plus)"
    return
  fi
  executer "$nom" "$binaire" "$@"
}

echo "== tests longs d'organum (racine $RACINE)"
echo "== dossier temporaire $TMP"

# --- API des réglages, serveur réel sur sortie muette ----------------------
if [ -x "$RACINE/web/build/organum.com" ]; then
  executer "API qualité (web/scripts/test-qualite.sh)" \
    sh "$RACINE/web/scripts/test-qualite.sh"
  executer "délai de première réponse (web/scripts/test-demarrage.sh)" \
    sh "$RACINE/web/scripts/test-demarrage.sh"
  executer "mode dégradé sans backend (web/scripts/test-sans-backend.sh)" \
    sh "$RACINE/web/scripts/test-sans-backend.sh"
  executer "MIDI par socket macOS (web/scripts/test-midi-socket.sh)" \
    sh "$RACINE/web/scripts/test-midi-socket.sh"
  executer "audio par socket macOS (web/scripts/test-audio-socket.sh)" \
    sh "$RACINE/web/scripts/test-audio-socket.sh"
  executer "authentification Digest (web/scripts/test-authentification.sh)" \
    sh "$RACINE/web/scripts/test-authentification.sh"
  executer "contrôle d'accès par sous-réseau (web/scripts/test-reseaux.sh)" \
    sh "$RACINE/web/scripts/test-reseaux.sh"
  executer "transposition (web/scripts/test-transposition.sh)" \
    sh "$RACINE/web/scripts/test-transposition.sh"
  executer "clavier web (web/scripts/test-clavier.sh)" \
    sh "$RACINE/web/scripts/test-clavier.sh"
else
  ignore "API qualité (web/build/organum.com absent ; lancer web/scripts/build.sh)"
  ignore "délai de première réponse (web/build/organum.com absent ; lancer web/scripts/build.sh)"
  ignore "mode dégradé sans backend (web/build/organum.com absent ; lancer web/scripts/build.sh)"
  ignore "MIDI par socket macOS (web/build/organum.com absent ; lancer web/scripts/build.sh)"
  ignore "audio par socket macOS (web/build/organum.com absent ; lancer web/scripts/build.sh)"
  ignore "authentification Digest (web/build/organum.com absent ; lancer web/scripts/build.sh)"
  ignore "contrôle d'accès par sous-réseau (web/build/organum.com absent ; lancer web/scripts/build.sh)"
  ignore "transposition (web/build/organum.com absent ; lancer web/scripts/build.sh)"
  ignore "clavier web (web/build/organum.com absent ; lancer web/scripts/build.sh)"
fi

# --- Couche plate-forme sans carte -----------------------------------------
# Règles de mesure de cadence de la validation macOS : pures, donc
# éprouvables ici sans macOS (pic de charge toléré, défaut structurel refusé).
executer "règles de cadence audio (plateforme/macos/tests/tester_cadence.sh)" \
  sh "$RACINE/plateforme/macos/tests/tester_cadence.sh"

# scripts/tester.sh construit et exécute les tests ALSA/MIDI sans matériel
# (chemins, injection, boucle d'écriture, ports MIDI, diagnostic libasound).
if [ -f "$RACINE/externe/cosmopolitan/Makefile" ]; then
  executer "plate-forme sans carte (scripts/tester.sh)" \
    sh "$RACINE/scripts/tester.sh"
else
  ignore "plate-forme sans carte (arbre cosmopolitan absent)"
fi

# --- Bancs du moteur -------------------------------------------------------
MOTEUR_PRET=0
if [ -f "$RACINE/externe/cosmocc/bin/cosmoc++" ]; then
  journal="$TMP/journaux/moteur.compilation.log"
  if make -C "$RACINE/moteur" -j"$(nproc)" >"$journal" 2>&1; then
    MOTEUR_PRET=1
  else
    echo "---- sortie de la construction du moteur ----"
    sed 's/^/        /' "$journal"
    echo "---------------------------------------------"
    ignore "bancs du moteur (libaeolus.a ne se compile pas)"
  fi
else
  ignore "bancs du moteur (chaîne cosmocc absente)"
fi

if [ "$MOTEUR_PRET" -eq 1 ]; then
  # Bancs liés à libaeolus.a. Aucun n'ouvre de carte son : tous rendent en
  # mémoire, donc utilisables sur une machine sans audio.
  banc "rendu hors ligne" rendu.cpp "$TMP/rendu.wav"
  banc "charge par défaut" charge.cpp
  banc "charge par niveau" charge_niveaux.cpp
  banc "niveau sonore par spatialisation" niveau_sonore.cpp
  banc "qualité du moteur" qualite.cpp
  banc "tempérament" temperament.cpp
  banc "tête de réverbération" tete.cpp
  banc "calibration automatique" calibration.cpp
  banc "vol de voix" vol_voix.cpp
  banc "sacrifice des doublons" vol_doublons.cpp
  banc "équivalence SIMD" equiv_simd.cpp
  banc "équivalence retard" equiv_delay.cpp
  banc "équivalence filtre" equiv_filter.cpp
  banc "équivalence spatialisation" equiv_spatial.cpp
  banc "équivalence voix spatiale" equiv_voix_spatial.cpp
  banc "écrêtage et limiteur" ecretage.cpp
  banc "polyphonie accouplée" polyphonie.cpp
fi

FIN_NS=$(date +%s%N)
echo
echo "== $OKS OK, $ECHECS échec(s), $IGNORES ignoré(s), total $(duree "$DEBUT_NS" "$FIN_NS")"
[ "$ECHECS" -eq 0 ]
