#!/bin/sh
# Authentification HTTP Digest SHA-256 : serveur réel sur sortie muette.
# Aucune requête ne sort de la machine : le serveur écoute sur 0.0.0.0 et
# les contrôles non locaux visent une adresse de l'hôte (ou 127.0.0.2 avec
# une source forcée), jamais orgue.lan ni l'extérieur.
#
#   web/scripts/test-authentification.sh
#
# Code 0 si aucun échec ; les contrôles IGNORÉ ne font pas échouer la suite.
set -u

ulimit -r 0 2>/dev/null || {
  echo "ÉCHEC : ulimit -r 0 impossible ; ne pas lancer le moteur sans temps réel" >&2
  exit 2
}
unset WAYLAND_DISPLAY DISPLAY

RACINE="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$RACINE/build/organum.com"
[ -x "$BIN" ] || { echo "ÉCHEC : $BIN absent (lancer web/scripts/build.sh)" >&2; exit 2; }

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
AUTH="$ETAT.authentification.json"
JOURNAL="$TMP/organum.log"
PID=""
ECHECS=0
IGNORES=0
OKS=0

arreter() {
  if [ -n "$PID" ]; then
    kill -KILL "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
    PID=""
  fi
}
nettoyer() { arreter; rm -rf "$TMP"; }
trap nettoyer EXIT
trap 'nettoyer; exit 130' INT TERM

ok() { OKS=$((OKS + 1)); echo "OK    : $1"; }
echec() { ECHECS=$((ECHECS + 1)); echo "ÉCHEC : $1"; }
ignore() { IGNORES=$((IGNORES + 1)); echo "IGNORÉ : $1"; }

port_libre() {
  ! curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$1/api/orgue" 2>/dev/null
}

PORT=18150
while ! port_libre "$PORT"; do PORT=$((PORT + 1)); done

# Adresse non locale : une adresse globale de l'hôte, sinon 127.0.0.2 avec
# une source forcée (le client local est alors 127.0.0.2, pas 127.0.0.1).
IP=""
for a in $(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1); do
  IP="$a"
  break
done
if [ -n "$IP" ]; then
  HOTE="$IP"
  OPT_IFACE=""
else
  HOTE="127.0.0.2"
  OPT_IFACE="--interface 127.0.0.2"
  ignore "aucune adresse globale : contrôles non locaux via 127.0.0.2 (source forcée)"
fi
URL="http://$HOTE:$PORT"
URL_LOCAL="http://127.0.0.1:$PORT"

# lancer [durée du nonce] : démarre l'orgue sur 0.0.0.0, sortie muette.
lancer() {
  duree=${1:-}
  arreter
  rm -f "$AUTH"
  if [ -n "$duree" ]; then
    ORGANUM_AUTH_NONCE_DUREE="$duree" \
    ORGANUM_PERIPHERIQUE=null ORGANUM_QUALITE=3 \
    ORGANUM_ETAT="$ETAT" ORGANUM_CONFIG_MIDI="$CONFIG" ORGANUM_FENETRE=non \
    "$BIN" -p "$PORT" >"$JOURNAL" 2>&1 &
  else
    unset ORGANUM_AUTH_NONCE_DUREE
    ORGANUM_PERIPHERIQUE=null ORGANUM_QUALITE=3 \
    ORGANUM_ETAT="$ETAT" ORGANUM_CONFIG_MIDI="$CONFIG" ORGANUM_FENETRE=non \
    "$BIN" -p "$PORT" >"$JOURNAL" 2>&1 &
  fi
  PID=$!
  i=0
  while [ "$i" -lt 400 ]; do
    if curl -s --max-time 1 -o /dev/null "$URL_LOCAL/api/orgue"; then
      if curl -s "$URL_LOCAL/api/orgue" | grep -qF '"temps_reel":true'; then
        echec "temps réel actif malgré ulimit -r 0"
        return 1
      fi
      return 0
    fi
    if ! kill -0 "$PID" 2>/dev/null; then
      echo "ÉCHEC : organum s'est arrêté au démarrage" >&2
      sed 's/^/        /' "$JOURNAL" >&2
      return 1
    fi
    sleep 0.1
    i=$((i + 1))
  done
  echo "ÉCHEC : organum ne répond pas sur $URL_LOCAL" >&2
  sed 's/^/        /' "$JOURNAL" >&2
  return 1
}

# client <méthode> <chemin> [options curl…] : requête depuis l'adresse non
# locale, avec les options données.
client() {
  methode=$1; chemin=$2; shift 2
  # shellcheck disable=SC2086
  curl -s $OPT_IFACE -X "$methode" "$@" "$URL$chemin"
}

code_client() {
  methode=$1; chemin=$2; shift 2
  # shellcheck disable=SC2086
  curl -s $OPT_IFACE -o /dev/null -w '%{http_code}' -X "$methode" "$@" "$URL$chemin"
}

poster_auth() {
  client POST /api/authentification -H 'Content-Type: application/json' -d "$1"
}

# en-tete_auth <nonce> <mot de passe> <chemin> : construit un Authorization
# Digest valide pour un nonce donné (même périmé), avec nc/cnonce fixes.
en-tete_auth() {
  nonce=$1; mot=$2; chemin=$3
  python3 - "$nonce" "$mot" "$chemin" <<'PY'
import hashlib, sys
nonce, mot, uri = sys.argv[1], sys.argv[2], sys.argv[3]
realm, user, nc, cnonce = "organum", "organiste", "00000001", "0123456789abcdef"
ha1 = hashlib.sha256(f"{user}:{realm}:{mot}".encode()).hexdigest()
ha2 = hashlib.sha256(f"GET:{uri}".encode()).hexdigest()
rep = hashlib.sha256(f"{ha1}:{nonce}:{nc}:{cnonce}:auth:{ha2}".encode()).hexdigest()
print(f'Authorization: Digest username="{user}", realm="{realm}", uri="{uri}", '
      f'algorithm=SHA-256, nonce="{nonce}", nc={nc}, cnonce="{cnonce}", '
      f'qop=auth, response="{rep}"')
PY
}

echo "== authentification Digest SHA-256 (port $PORT, hôte $HOTE)"
lancer || exit 1

# 1. Désactivée par défaut, y compris depuis une adresse non locale.
CODE=$(code_client GET /api/orgue)
[ "$CODE" = 200 ] && ok "désactivée par défaut : non locale acceptée (200)" \
  || echec "désactivée par défaut : code $CODE"
ETAT_AUTH=$(client GET /api/authentification)
printf '%s' "$ETAT_AUTH" | grep -qF '"active":false' \
  && ok "état initial : inactive" || echec "état initial inattendu : $ETAT_AUTH"

# 2. Définition du mot de passe (possible tant qu'aucun n'existe), puis 401.
REP=$(poster_auth '{"utilisateur":"organiste","mot_de_passe":"secret01"}')
printf '%s' "$REP" | grep -qF '"active":true' \
  && ok "mot de passe défini" || echec "définition refusée : $REP"
CODE=$(code_client GET /api/orgue)
[ "$CODE" = 401 ] && ok "sans identifiant : 401" || echec "sans identifiant : code $CODE"
ENTETE=$(client GET /api/orgue -D - -o /dev/null | tr -d '\r' | grep -i '^www-authenticate:')
case "$ENTETE" in
  *Digest*realm=\"organum\"*qop=\"auth\"*algorithm=SHA-256*nonce=* )
    ok "défi Digest : realm, qop=auth, algorithm=SHA-256, nonce" ;;
  *) echec "défi Digest incomplet : $ENTETE" ;;
esac

# 3. Mauvais mot de passe refusé, bon mot de passe accepté (curl --digest).
CODE=$(code_client GET /api/orgue --digest -u organiste:mauvais)
[ "$CODE" = 401 ] && ok "mauvais mot de passe : 401" || echec "mauvais mot de passe : code $CODE"
CODE=$(code_client GET /api/orgue --digest -u organiste:secret01)
[ "$CODE" = 200 ] && ok "bon mot de passe : 200" || echec "bon mot de passe : code $CODE"
CODE=$(code_client GET "/api/orgue/attendre?instance=x&seq=1" --digest -u organiste:secret01)
[ "$CODE" = 200 ] && ok "attente longue authentifiée : 200" || echec "attente longue : code $CODE"
CODE=$(code_client GET /audio --digest -u organiste:secret01)
[ "$CODE" = 200 ] && ok "page /audio authentifiée : 200" || echec "page /audio : code $CODE"
CODE=$(code_client GET /api/orgue)
[ "$CODE" = 401 ] || echec "page locale non exemptée ? code $CODE"

# 4. Adresse locale exemptée.
CODE=$(curl -s -o /dev/null -w '%{http_code}' "$URL_LOCAL/api/orgue")
[ "$CODE" = 200 ] && ok "127.0.0.1 exempté : 200" || echec "127.0.0.1 : code $CODE"

# 5. Fichier : 0600, HA1 seulement, jamais le mot de passe.
if [ -f "$AUTH" ]; then
  MODE=$(stat -c '%a' "$AUTH")
  [ "$MODE" = 600 ] && ok "fichier d'authentification en 0600" \
    || echec "droits du fichier : $MODE"
  if grep -qF 'secret01' "$AUTH"; then
    echec "le mot de passe apparaît en clair dans $AUTH"
  else
    ok "mot de passe absent du fichier"
  fi
  ATTENDU=$(python3 -c 'import hashlib;print(hashlib.sha256(b"organiste:organum:secret01").hexdigest())')
  grep -qF "$ATTENDU" "$AUTH" && ok "HA1 attendu dans le fichier" \
    || echec "HA1 absent du fichier ($ATTENDU)"
  ETAT_AUTH=$(client GET /api/authentification --digest -u organiste:secret01)
  if printf '%s' "$ETAT_AUTH" | grep -qi 'ha1\|secret01'; then
    echec "l'API expose un haché ou le mot de passe : $ETAT_AUTH"
  else
    ok "l'API n'expose ni haché ni mot de passe"
  fi
else
  echec "fichier d'authentification absent"
fi

# 6. Retrait : de nouveau ouverte.
REP=$(client POST /api/authentification --digest -u organiste:secret01 \
  -H 'Content-Type: application/json' -d '{"retirer":true}')
printf '%s' "$REP" | grep -qF '"active":false' \
  && ok "mot de passe retiré" || echec "retrait refusé : $REP"
[ ! -f "$AUTH" ] && ok "fichier supprimé" || echec "fichier toujours présent après retrait"
CODE=$(code_client GET /api/orgue)
[ "$CODE" = 200 ] && ok "après retrait : non locale acceptée" || echec "après retrait : code $CODE"

# 7. Nonce périmé : stale=true, puis curl rejoue sans redemander le mot de passe.
lancer 1 || exit 1
REP=$(poster_auth '{"utilisateur":"organiste","mot_de_passe":"secret02"}') || true
printf '%s' "$REP" | grep -qF '"active":true' || echec "redéfinition : $REP"
NONCE=$(client GET /api/orgue -D - -o /dev/null | tr -d '\r' \
  | sed -n 's/.*nonce="\([^"]*\)".*/\1/p' | head -n 1)
if [ -n "$NONCE" ]; then
  sleep 2
  ENTETE_PERIME=$(en-tete_auth "$NONCE" secret02 /api/orgue)
  REPONSE=$(curl -s $OPT_IFACE -D - -o /dev/null -H "$ENTETE_PERIME" "$URL/api/orgue" | tr -d '\r')
  case "$REPONSE" in
    *" 401 "*) ok "nonce périmé : 401" ;;
    *) echec "nonce périmé : réponse inattendue" ;;
  esac
  printf '%s' "$REPONSE" | grep -qi 'stale=true' \
    && ok "nonce périmé : stale=true" || echec "nonce périmé : stale absent"
  CODE=$(code_client GET /api/orgue --digest -u organiste:secret02)
  [ "$CODE" = 200 ] && ok "nonce périmé : curl rejoue sans redemander (200)" \
    || echec "rejeu après stale : code $CODE"
else
  echec "nonce introuvable dans le défi"
fi

# 8. ORGANUM_MOT_DE_PASSE prioritaire, non recopié sur disque, verrouille.
forcer_env() {
  arreter
  rm -f "$AUTH"
  ORGANUM_MOT_DE_PASSE=secret03 \
  ORGANUM_PERIPHERIQUE=null ORGANUM_QUALITE=3 \
  ORGANUM_ETAT="$ETAT" ORGANUM_CONFIG_MIDI="$CONFIG" ORGANUM_FENETRE=non \
  "$BIN" -p "$PORT" >"$JOURNAL" 2>&1 &
  PID=$!
  i=0
  while [ "$i" -lt 400 ]; do
    curl -s --max-time 1 -o /dev/null "$URL_LOCAL/api/orgue" && return 0
    kill -0 "$PID" 2>/dev/null || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}
if forcer_env; then
  CODE=$(code_client GET /api/orgue --digest -u organiste:secret03)
  [ "$CODE" = 200 ] && ok "ORGANUM_MOT_DE_PASSE : authentification active" \
    || echec "ORGANUM_MOT_DE_PASSE : code $CODE"
  CODE=$(code_client POST /api/authentification --digest -u organiste:secret03 \
    -H 'Content-Type: application/json' -d '{"mot_de_passe":"autre"}')
  [ "$CODE" = 409 ] && ok "réglage verrouillé par l'environnement (409)" \
    || echec "réglage sous environnement : code $CODE"
  [ ! -f "$AUTH" ] && ok "ORGANUM_MOT_DE_PASSE non recopié sur disque" \
    || echec "fichier écrit malgré l'environnement"
  ETAT_AUTH=$(client GET /api/authentification --digest -u organiste:secret03)
  printf '%s' "$ETAT_AUTH" | grep -qF '"impose":true' \
    && ok "état : impose=true" || echec "état sous environnement : $ETAT_AUTH"
else
  echec "démarrage avec ORGANUM_MOT_DE_PASSE"
fi

arreter
echo
echo "== $OKS OK, $ECHECS échec(s), $IGNORES ignoré(s)"
[ "$ECHECS" -eq 0 ]
