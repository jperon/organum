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

# Repart d'un premier lancement : ni etat.json ni son fichier de qualité.
effacer_etat() {
  arreter
  rm -f "$ETAT" "$ETAT.qualite.json"
}

unset ORGANUM_QUALITE ORGANUM_REVERB_TETE ORGANUM_CALIBRATION_FACTEUR

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

echo
if [ "$ECHECS" -eq 0 ]; then
  echo "Tous les contrôles : OK"
  exit 0
fi
echo "$ECHECS contrôle(s) en échec"
exit 1
