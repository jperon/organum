#!/bin/sh
# Tests de l'API des réglages de qualité (backend Lua/HTTP + persistance).
# Lance web/build/organum.com sur un port libre avec un état temporaire et un
# périphérique ALSA muet (null) : aucun son n'est produit. Le processus lancé
# est arrêté par son PID (jamais pkill -f).
# Sortie : une ligne OK/ÉCHEC par contrôle ; code de retour non nul si échec.
set -u

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

# lancer [ORGANUM_QUALITE] : démarre l'orgue et attend qu'il réponde.
lancer() {
  qualite=$1
  unset ORGANUM_QUALITE
  if [ -n "$qualite" ]; then
    ORGANUM_QUALITE="$qualite" \
    ORGANUM_ETAT="$ETAT" \
    ORGANUM_CONFIG_MIDI="$CONFIG" \
    ORGANUM_FENETRE=non \
    ORGANUM_PERIPHERIQUE=null \
    "$BIN" -p "$PORT" >"$JOURNAL" 2>&1 &
  else
    ORGANUM_ETAT="$ETAT" \
    ORGANUM_CONFIG_MIDI="$CONFIG" \
    ORGANUM_FENETRE=non \
    ORGANUM_PERIPHERIQUE=null \
    "$BIN" -p "$PORT" >"$JOURNAL" 2>&1 &
  fi
  PID=$!
  i=0
  # Le moteur charge ses ressources avant d'écouter : jusqu'à ~2 min sur une
  # machine chargée. Chaque essai est borné pour ne jamais bloquer.
  while [ "$i" -lt 200 ]; do
    if curl -s --connect-timeout 1 --max-time 1 -o /dev/null "$URL/api/orgue"; then
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

unset ORGANUM_QUALITE ORGANUM_REVERB_TETE

echo "== démarrage sur le port $PORT (état temporaire $TMP)"
lancer "" || exit 1

echo "== valeurs par défaut"
S=$(get)
verifie "spatialisation par défaut = 2" '"spatialisation":2' "$S"
verifie "bruit_attaque par défaut = true" '"bruit_attaque":true' "$S"
verifie "instabilite par défaut = true" '"instabilite":true' "$S"
verifie "polyphonie_max par défaut = 0" '"polyphonie_max":0' "$S"
verifie "tete_reverb par défaut = true" '"tete_reverb":true' "$S"
verifie "auto par défaut = false" '"auto":false' "$S"

echo "== POST valide : un seul champ"
R=$(post '{"qualite":{"spatialisation":1}}')
verifie "réponse 200 avec ok" '"ok":true' "$R"
attendre_publication
S=$(get)
verifie "spatialisation appliquée = 1" '"spatialisation":1' "$S"
verifie "modification individuelle : niveau = -1" '"niveau":-1' "$S"
verifie "modification individuelle : auto = false" '"auto":false' "$S"

echo "== POST valide : plusieurs champs"
R=$(post '{"qualite":{"bruit_attaque":false,"instabilite":false,"polyphonie_max":128}}')
verifie "réponse 200 avec ok" '"ok":true' "$R"
attendre_publication
S=$(get)
verifie "bruit_attaque appliqué = false" '"bruit_attaque":false' "$S"
verifie "instabilite appliquée = false" '"instabilite":false' "$S"
verifie "polyphonie_max appliquée = 128" '"polyphonie_max":128' "$S"

echo "== POST valide : niveau 1 (présélection d'un coup)"
R=$(post '{"qualite":{"niveau":1}}')
verifie "réponse 200 avec ok" '"ok":true' "$R"
verifie "changement de tete_reverb : redemarrage_requis = true" '"redemarrage_requis":true' "$R"
attendre_publication
S=$(get)
verifie "niveau 1 : spatialisation = 1" '"spatialisation":1' "$S"
verifie "niveau 1 : bruit_attaque = false" '"bruit_attaque":false' "$S"
verifie "niveau 1 : instabilite = false" '"instabilite":false' "$S"
verifie "niveau 1 : polyphonie_max = 160" '"polyphonie_max":160' "$S"
verifie "niveau 1 : tete_reverb = false" '"tete_reverb":false' "$S"
verifie "niveau 1 : niveau = 1" '"niveau":1' "$S"

echo "== POST invalides (400)"
for cas in \
  '{"qualite":{"inconnu":1}}|champ inconnu' \
  '{"qualite":{"bruit_attaque":1}}|type faux' \
  '{"qualite":{"spatialisation":3}}|valeur hors bornes' \
  '{"qualite":{}}|objet vide' \
  '{"qualite":{"polyphonie_max":513}}|polyphonie hors bornes' \
  '{"qualite":{"niveau":4}}|niveau hors bornes'
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

echo "== persistance dans etat.json"
post '{"qualite":{"niveau":2}}' >/dev/null
post '{"qualite":{"auto":true}}' >/dev/null
attendre_publication
attendre_sauvegarde
verifie "etat.json contient la clé qualite" '"qualite"' "$(cat "$ETAT" 2>/dev/null || true)"
arreter
lancer "" || exit 1
S=$(get)
verifie "après relance : niveau 2 restauré" '"niveau":2' "$S"
verifie "après relance : auto true restauré" '"auto":true' "$S"
verifie "après relance : polyphonie_max = 256" '"polyphonie_max":256' "$S"
verifie "après relance : tete_reverb = true" '"tete_reverb":true' "$S"

echo "== ORGANUM_QUALITE=1 prioritaire sur le fichier"
arreter
lancer 1 || exit 1
S=$(get)
verifie "ORGANUM_QUALITE=1 : niveau = 1" '"niveau":1' "$S"
verifie "ORGANUM_QUALITE=1 : spatialisation = 1" '"spatialisation":1' "$S"
verifie "ORGANUM_QUALITE=1 : polyphonie_max = 160" '"polyphonie_max":160' "$S"
verifie "ORGANUM_QUALITE=1 : tete_reverb = false" '"tete_reverb":false' "$S"

arreter

echo
if [ "$ECHECS" -eq 0 ]; then
  echo "Tous les contrôles : OK"
  exit 0
fi
echo "$ECHECS contrôle(s) en échec"
exit 1
