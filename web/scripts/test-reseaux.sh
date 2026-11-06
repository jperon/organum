#!/bin/sh
# Contrôle d'accès par sous-réseau source : serveur réel sur sortie muette.
# Aucune requête ne sort de la machine : les sources « non locales » sont une
# adresse globale de l'hôte quand il y en a une, sinon 127.0.0.2 et 127.0.0.3
# (non exemptées : seules 127.0.0.1 et ::1 le sont). Jamais orgue.lan ni
# l'extérieur.
#
#   web/scripts/test-reseaux.sh
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
PROTEGE="$TMP/protege"
ETAT="$TMP/etat.json"
CONFIG="$TMP/midi.json"
AUTH="$ETAT.digest"
RESEAUX="$ETAT.reseaux"
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
nettoyer() {
  arreter
  chmod -R u+rwx "$TMP" 2>/dev/null || true
  rm -rf "$TMP"
}
trap nettoyer EXIT
trap 'nettoyer; exit 130' INT TERM

ok() { OKS=$((OKS + 1)); echo "OK    : $1"; }
echec() { ECHECS=$((ECHECS + 1)); echo "ÉCHEC : $1"; }
ignore() { IGNORES=$((IGNORES + 1)); echo "IGNORÉ : $1"; }

port_libre() {
  ! curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$1/api/orgue" 2>/dev/null
}

PORT=18250
while ! port_libre "$PORT"; do PORT=$((PORT + 1)); done

IP4=""
for a in $(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1); do
  IP4="$a"
  break
done
if [ -n "$IP4" ]; then
  URL_NL="http://$IP4:$PORT"
  OPT_NL=""
else
  URL_NL="http://127.0.0.1:$PORT"
  OPT_NL="--interface 127.0.0.2"
  ignore "aucune adresse IPv4 globale : source non locale via 127.0.0.2"
fi
URL_LOCAL="http://127.0.0.1:$PORT"
# Source « autre », toujours distincte de la précédente et non locale.
if [ -n "$IP4" ]; then
  OPT_AUTRE="--interface 127.0.0.2"
else
  OPT_AUTRE="--interface 127.0.0.3"
fi

IP6=""
for a in $(ip -6 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1); do
  IP6="$a"
  break
done
LIGNE_LINK=$(ip -6 -o addr show scope link 2>/dev/null | awk '$2 != "lo" {print $2" "$4; exit}')
LINK_IF=""
LINK_ADDR=""
if [ -n "$LIGNE_LINK" ]; then
  LINK_IF=${LIGNE_LINK%% *}
  LINK_ADDR=${LIGNE_LINK#* }
  LINK_ADDR=${LINK_ADDR%/*}
fi

champ() {
  python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1],""))' "$1"
}

# lancer [garder] : démarre l'orgue, sortie muette. Sans « garder », efface
# les fichiers Digest et réseaux.
lancer() {
  arreter
  [ "${1:-}" = "garder" ] || rm -f "$RESEAUX" "$AUTH"
  ORGANUM_PERIPHERIQUE=null ORGANUM_QUALITE=3 \
  ORGANUM_ETAT="$ETAT" ORGANUM_CONFIG_MIDI="$CONFIG" ORGANUM_FENETRE=non \
  "$BIN" -p "$PORT" >"$JOURNAL" 2>&1 &
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

# démarre sans effacer les fichiers ; ORGANUM_RESEAUX_FICHIER vaut la valeur
# donnée (__ABSENT__ : variable retirée).
demarrer_direct() {
  arreter
  if [ "$1" = "__ABSENT__" ]; then
    unset ORGANUM_RESEAUX_FICHIER
  else
    ORGANUM_RESEAUX_FICHIER="$1"
    export ORGANUM_RESEAUX_FICHIER
  fi
  ORGANUM_PERIPHERIQUE=null ORGANUM_QUALITE=3 \
  ORGANUM_ETAT="$ETAT" ORGANUM_CONFIG_MIDI="$CONFIG" ORGANUM_FENETRE=non \
    "$BIN" -p "$PORT" >"$JOURNAL" 2>&1 &
  PID=$!
  i=0
  while [ "$i" -lt 400 ]; do
    if curl -s --max-time 1 -o /dev/null "$URL_LOCAL/api/orgue"; then
      unset ORGANUM_RESEAUX_FICHIER
      return 0
    fi
    if ! kill -0 "$PID" 2>/dev/null; then
      unset ORGANUM_RESEAUX_FICHIER
      return 1
    fi
    sleep 0.1
    i=$((i + 1))
  done
  unset ORGANUM_RESEAUX_FICHIER
  return 1
}

# client_nl / code_nl : source non locale (adresse globale ou 127.0.0.2).
client_nl() {
  methode=$1; chemin=$2; shift 2
  # shellcheck disable=SC2086
  curl -s $OPT_NL -X "$methode" "$@" "$URL_NL$chemin"
}
code_nl() {
  methode=$1; chemin=$2; shift 2
  # shellcheck disable=SC2086
  curl -s $OPT_NL -o /dev/null -w '%{http_code}' -X "$methode" "$@" "$URL_NL$chemin"
}

# client_autre / code_autre : autre source non locale.
client_autre() {
  methode=$1; chemin=$2; shift 2
  # shellcheck disable=SC2086
  curl -s $OPT_AUTRE -X "$methode" "$@" "$URL_LOCAL$chemin"
}
code_autre() {
  methode=$1; chemin=$2; shift 2
  # shellcheck disable=SC2086
  curl -s $OPT_AUTRE -o /dev/null -w '%{http_code}' -X "$methode" "$@" "$URL_LOCAL$chemin"
}

# code_local / client_local.
code_local() {
  methode=$1; chemin=$2; shift 2
  curl -s -o /dev/null -w '%{http_code}' -X "$methode" "$@" "$URL_LOCAL$chemin"
}
client_local() {
  methode=$1; chemin=$2; shift 2
  curl -s -X "$methode" "$@" "$URL_LOCAL$chemin"
}

poster_reseaux() {
  # poster_reseaux <client> <json>
  fonction=$1; json=$2
  "$fonction" POST /api/reseaux -H 'Content-Type: application/json' -d "$json"
}
poster_reseaux_local() { poster_reseaux client_local "$1"; }
poster_auth_local() {
  client_local POST /api/authentification -H 'Content-Type: application/json' -d "$1"
}
definir_mot_de_passe() { poster_auth_local '{"utilisateur":"organiste","mot_de_passe":"secret01"}'; }
retirer_mot_de_passe() { poster_auth_local '{"retirer":true}'; }

echo "== contrôle d'accès par sous-réseau (port $PORT, sources $IP4/127.0.0.2)"
lancer || exit 1
SRC_NL=$(client_nl GET /api/reseaux | champ source)
SRC_AUTRE=$(client_autre GET /api/reseaux | champ source)
[ -n "$SRC_NL" ] && [ -n "$SRC_AUTRE" ] \
  && ok "sources découvertes : $SRC_NL et $SRC_AUTRE" \
  || echec "sources introuvables (nl='$SRC_NL', autre='$SRC_AUTRE')"
[ "$SRC_NL" != "$SRC_AUTRE" ] \
  && ok "les deux sources diffèrent" \
  || echec "même source des deux côtés ($SRC_NL)"

# Cas 1 : liste vide, pas de mot de passe → aucun contrôle.
[ "$(code_nl GET /api/orgue)" = 200 ] && ok "cas 1 : source non locale acceptée (200)" \
  || echec "cas 1 : code $(code_nl GET /api/orgue)"
[ "$(code_autre GET /api/orgue)" = 200 ] && ok "cas 1 : autre source acceptée (200)" \
  || echec "cas 1 : autre code $(code_autre GET /api/orgue)"
[ "$(code_local GET /api/orgue)" = 200 ] && ok "cas 1 : locale acceptée (200)" \
  || echec "cas 1 : locale code $(code_local GET /api/orgue)"

# Sous-réseau IPv4 : /24 de l'adresse globale, sinon /32 exact.
case "$SRC_NL" in
  127.*) RESEAU_NL="$SRC_NL/32" ;;
  *.*.*.*) RESEAU_NL="$(printf '%s' "$SRC_NL" | cut -d. -f1-3).0/24" ;;
  *) RESEAU_NL="$SRC_NL/32" ;;
esac
REP=$(poster_reseaux_local "{\"reseaux\":\"$RESEAU_NL\"}")
printf '%s' "$REP" | grep -qF '"active":true' \
  && ok "liste IPv4 enregistrée ($RESEAU_NL)" || echec "enregistrement refusé : $REP"

# Cas 3 : liste remplie, pas de mot de passe → sous-réseau seul.
[ "$(code_nl GET /api/orgue)" = 200 ] && ok "cas 3 : source listée acceptée (200)" \
  || echec "cas 3 : source listée code $(code_nl GET /api/orgue)"
[ "$(code_autre GET /api/orgue)" = 403 ] && ok "cas 3 : source hors liste refusée (403)" \
  || echec "cas 3 : hors liste code $(code_autre GET /api/orgue)"
[ "$(code_local GET /api/orgue)" = 200 ] && ok "cas 3 : locale toujours acceptée (200)" \
  || echec "cas 3 : locale code $(code_local GET /api/orgue)"
[ "$(code_autre GET /api/orgue -H "X-Forwarded-For: $SRC_NL")" = 403 ] \
  && ok "X-Forwarded-For ignoré (403)" \
  || echec "X-Forwarded-For a contourné le filtre"

ENTETES=$(client_autre GET /api/orgue -D - -o /dev/null)
printf '%s' "$ENTETES" | grep -q '^HTTP/[^ ]* 403' \
  && ok "hors liste : 403" || echec "hors liste : pas de 403"
if printf '%s' "$ENTETES" | grep -qi '^www-authenticate:'; then
  echec "403 hors liste porte un WWW-Authenticate"
else
  ok "403 hors liste sans WWW-Authenticate"
fi

# Cas 4 : les deux → sous-réseau PUIS Digest.
definir_mot_de_passe >/dev/null
[ "$(code_nl GET /api/orgue)" = 401 ] && ok "cas 4 : source listée sans identifiant → 401" \
  || echec "cas 4 : source listée sans identifiant code $(code_nl GET /api/orgue)"
ENTETE_401=$(client_nl GET /api/orgue -D - -o /dev/null)
printf '%s' "$ENTETE_401" | grep -qi '^www-authenticate:.*Digest' \
  && ok "cas 4 : défi Digest présent sur 401" || echec "cas 4 : défi Digest absent"
[ "$(code_nl GET /api/orgue --digest -u organiste:secret01)" = 200 ] \
  && ok "cas 4 : source listée + Digest → 200" \
  || echec "cas 4 : source listée + Digest code $(code_nl GET /api/orgue --digest -u organiste:secret01)"
[ "$(code_autre GET /api/orgue --digest -u organiste:secret01)" = 403 ] \
  && ok "cas 4 : hors liste + Digest → 403" \
  || echec "cas 4 : hors liste + Digest code $(code_autre GET /api/orgue --digest -u organiste:secret01)"
ENTETES=$(client_autre GET /api/orgue --digest -u organiste:secret01 -D - -o /dev/null)
if printf '%s' "$ENTETES" | grep -qi '^www-authenticate:'; then
  echec "hors liste + Digest : WWW-Authenticate présent"
else
  ok "hors liste + Digest : aucun WWW-Authenticate"
fi
retirer_mot_de_passe >/dev/null

# IPv6 : lien-local avec zone côté client, sans zone côté serveur.
if [ -n "$LINK_ADDR" ]; then
  URL6_LINK="http://[${LINK_ADDR}%25${LINK_IF}]:$PORT"
  # Liste vide pour que la source soit publiée (hors liste : 403 sans source).
  poster_reseaux_local '{"retirer":true}' >/dev/null
  SRC6_LINK=$(curl -s --max-time 2 "$URL6_LINK/api/reseaux" | champ source)
  case "$SRC6_LINK" in
    *%*) echec "la source IPv6 contient encore une zone : $SRC6_LINK" ;;
    "$LINK_ADDR") ok "source lien-local sans zone ($SRC6_LINK)" ;;
    *) echec "source lien-local inattendue : '$SRC6_LINK' (attendu $LINK_ADDR)" ;;
  esac
  poster_reseaux_local '{"reseaux":"fe80::/10"}' >/dev/null
  [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$URL6_LINK/api/orgue")" = 200 ] \
    && ok "IPv6 lien-local dans fe80::/10 → 200 (zone ignorée)" \
    || echec "IPv6 lien-local dans fe80::/10 refusé"
  if [ -n "$IP6" ]; then
    [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://[$IP6]:$PORT/api/orgue")" = 403 ] \
      && ok "IPv6 global hors fe80::/10 → 403" \
      || echec "IPv6 global hors fe80::/10 non refusé"
  else
    ignore "aucune IPv6 globale : hors-liste IPv6 non testée"
  fi
else
  ignore "aucune adresse IPv6 lien-local : contrôles IPv6 ignorés"
fi
poster_reseaux_local '{"retirer":true}' >/dev/null

# Cas 2 : liste vide, mot de passe → Digest seul.
definir_mot_de_passe >/dev/null
[ "$(code_autre GET /api/orgue)" = 401 ] && ok "cas 2 : liste vide + mot de passe → 401" \
  || echec "cas 2 : code $(code_autre GET /api/orgue)"
[ "$(code_local GET /api/orgue)" = 200 ] && ok "cas 2 : locale exemptée (200)" \
  || echec "cas 2 : locale code $(code_local GET /api/orgue)"
retirer_mot_de_passe >/dev/null

# Refus d'auto-exclusion : depuis une source non locale, puis locale.
REP=$(poster_reseaux client_autre "{\"reseaux\":\"$RESEAU_NL\"}")
printf '%s' "$REP" | grep -qF 'exclut' \
  && ok "auto-exclusion refusée depuis une source non locale" \
  || echec "auto-exclusion non refusée : $REP"
CODE=$(code_autre POST /api/reseaux -H 'Content-Type: application/json' \
  -d "{\"reseaux\":\"$RESEAU_NL\"}")
[ "$CODE" = 400 ] && ok "auto-exclusion : 400" || echec "auto-exclusion : code $CODE"
CODE=$(code_local POST /api/reseaux -H 'Content-Type: application/json' \
  -d '{"reseaux":"10.0.0.0/8"}')
[ "$CODE" = 200 ] && ok "source locale : exclusion autorisée (200)" \
  || echec "source locale : code $CODE"
poster_reseaux_local '{"retirer":true}' >/dev/null

# Listes invalides : refus explicite (400).
for mauvais in '10.0.0.0/33' '10.35.1.2/16' 'nimportequoi' '2001:db8::/129'; do
  CODE=$(code_local POST /api/reseaux -H 'Content-Type: application/json' \
    -d "{\"reseaux\":\"$mauvais\"}")
  [ "$CODE" = 400 ] && ok "liste invalide refusée : $mauvais" \
    || echec "liste invalide acceptée ($mauvais, code $CODE)"
done

# Persistance : fichier texte voisin, 0600, une entrée par ligne.
poster_reseaux_local '{"reseaux":"10.35.0.0/16"}' >/dev/null
if [ -f "$RESEAUX" ]; then
  MODE=$(stat -c '%a' "$RESEAUX")
  [ "$MODE" = 600 ] && ok "fichier de réseaux en 0600" || echec "droits du fichier : $MODE"
  if grep -qxF "10.35.0.0/16" "$RESEAUX" && [ "$(grep -cv '^[[:space:]]*$' "$RESEAUX")" = 1 ]; then
    ok "fichier de réseaux : liste enregistrée en texte"
  else
    echec "liste absente ou format inattendu dans le fichier : $(cat "$RESEAUX")"
  fi
else
  echec "fichier de réseaux absent"
fi

# Fichier rendu invalide à chaud : accès non local refusé (503), local
# conservé, erreur publiée.
printf 'pas-un-reseau\n' >"$RESEAUX"
[ "$(code_autre GET /api/orgue)" = 503 ] \
  && ok "fichier invalide à chaud : non local 503" \
  || echec "fichier invalide à chaud : code $(code_autre GET /api/orgue)"
[ "$(code_local GET /api/orgue)" = 200 ] \
  && ok "fichier invalide à chaud : local conservé (200)" \
  || echec "fichier invalide à chaud : local code $(code_local GET /api/orgue)"
ERREUR=$(client_local GET /api/reseaux | champ erreur)
[ -n "$ERREUR" ] && ok "fichier invalide à chaud : erreur publiée ($ERREUR)" \
  || echec "fichier invalide à chaud : aucune erreur publiée"

# Fichier écrit à la main, commentaires et lignes vides : accepté tel quel.
arreter
printf '# réseaux de la maison\n\n%s\n' "$RESEAU_NL" >"$RESEAUX"
chmod 600 "$RESEAUX"
lancer garder || exit 1
[ "$(code_nl GET /api/orgue)" = 200 ] \
  && ok "fichier écrit à la main : source listée acceptée" \
  || echec "fichier écrit à la main : source listée code $(code_nl GET /api/orgue)"
[ "$(code_autre GET /api/orgue)" = 403 ] \
  && ok "fichier écrit à la main : source hors liste refusée" \
  || echec "fichier écrit à la main : hors liste code $(code_autre GET /api/orgue)"
grep -qF '# réseaux de la maison' "$RESEAUX" \
  && ok "fichier écrit à la main : commentaires conservés au démarrage" \
  || echec "fichier écrit à la main : commentaires perdus"

# ORGANUM_RESEAUX_FICHIER vide : repli sur le chemin par défaut, fichier
# toujours honoré.
demarrer_direct "" || { echec "démarrage avec ORGANUM_RESEAUX_FICHIER vide"; exit 1; }
[ "$(code_nl GET /api/orgue)" = 200 ] \
  && ok "ORGANUM_RESEAUX_FICHIER vide : chemin par défaut utilisé" \
  || echec "ORGANUM_RESEAUX_FICHIER vide : source listée code $(code_nl GET /api/orgue)"

# API par entrées {reseau, commentaire} : commentaire conservé, refusé s'il
# contient un saut de ligne ou dépasse 200 octets.
REP=$(poster_reseaux_local "{\"reseaux\":[{\"reseau\":\"$RESEAU_NL\",\"commentaire\":\"chapelle\"}]}")
printf '%s' "$REP" | grep -qF '"commentaire":"chapelle"' \
  && ok "API réseaux : entrée avec commentaire acceptée" \
  || echec "API réseaux : entrée avec commentaire refusée ($REP)"
grep -qxF "$RESEAU_NL # chapelle" "$RESEAUX" \
  && ok "API réseaux : commentaire écrit dans le fichier" \
  || echec "API réseaux : commentaire absent du fichier ($(cat "$RESEAUX"))"
CODE=$(code_local POST /api/reseaux -H 'Content-Type: application/json' \
  -d "{\"reseaux\":[{\"reseau\":\"$RESEAU_NL\",\"commentaire\":\"a\\nb\"}]}")
[ "$CODE" = 400 ] && ok "API réseaux : saut de ligne dans le commentaire refusé (400)" \
  || echec "API réseaux : saut de ligne accepté (code $CODE)"
LONG=$(python3 -c 'print("x"*201)')
CODE=$(code_local POST /api/reseaux -H 'Content-Type: application/json' \
  -d "{\"reseaux\":[{\"reseau\":\"$RESEAU_NL\",\"commentaire\":\"$LONG\"}]}")
[ "$CODE" = 400 ] && ok "API réseaux : commentaire de plus de 200 octets refusé (400)" \
  || echec "API réseaux : commentaire trop long accepté (code $CODE)"

# Fichier invalide au démarrage : l'orgue démarre quand même, 503 pour les
# sources non locales, et la source locale garde les pages et l'API pour
# corriger ; un POST local valide rétablit le contrôle.
arreter
printf 'pas-un-reseau\n' >"$RESEAUX"
demarrer_direct __ABSENT__ || { echec "fichier réseaux invalide au démarrage : le serveur n'a pas démarré"; exit 1; }
[ "$(code_nl GET /api/orgue)" = 503 ] \
  && ok "fichier réseaux invalide au démarrage : non local 503" \
  || echec "fichier réseaux invalide au démarrage : non local code $(code_nl GET /api/orgue)"
[ "$(code_local GET /audio)" = 200 ] \
  && ok "fichier réseaux invalide au démarrage : /audio local 200" \
  || echec "fichier réseaux invalide au démarrage : /audio local code $(code_local GET /audio)"
ERREUR=$(client_local GET /api/reseaux | champ erreur)
[ -n "$ERREUR" ] \
  && ok "fichier réseaux invalide au démarrage : erreur publiée" \
  || echec "fichier réseaux invalide au démarrage : aucune erreur publiée"
REP=$(poster_reseaux_local "{\"reseaux\":[{\"reseau\":\"$RESEAU_NL\",\"commentaire\":\"corrigé\"}]}")
printf '%s' "$REP" | grep -qF '"active":true' \
  && ok "fichier réseaux invalide : POST local valide accepté" \
  || echec "fichier réseaux invalide : POST local refusé ($REP)"
[ "$(code_nl GET /api/orgue)" = 200 ] \
  && ok "fichier réseaux corrigé : source listée acceptée (200)" \
  || echec "fichier réseaux corrigé : source listée code $(code_nl GET /api/orgue)"
[ "$(code_autre GET /api/orgue)" = 403 ] \
  && ok "fichier réseaux corrigé : contrôle rétabli (403 hors liste)" \
  || echec "fichier réseaux corrigé : hors liste code $(code_autre GET /api/orgue)"
grep -qxF "$RESEAU_NL # corrigé" "$RESEAUX" \
  && ok "fichier réseaux corrigé : commentaire conservé" \
  || echec "fichier réseaux corrigé : commentaire absent"

# Dossier parent inaccessible (EACCES) : ce n'est pas « absent », donc 503
# pour les sources non locales plutôt qu'une ouverture, accès local conservé.
if [ "$(id -u)" -eq 0 ]; then
  ignore "dossier parent inaccessible (EACCES) : sans objet en root"
else
  arreter
  rm -rf "$PROTEGE"
  mkdir -p "$PROTEGE"
  chmod 000 "$PROTEGE"
  demarrer_direct "$PROTEGE/reseaux" \
    || { echec "démarrage avec dossier parent inaccessible"; exit 1; }
  [ "$(code_autre GET /api/orgue)" = 503 ] \
    && ok "dossier parent inaccessible : non local 503" \
    || echec "dossier parent inaccessible : non local code $(code_autre GET /api/orgue)"
  [ "$(code_local GET /api/orgue)" = 200 ] \
    && ok "dossier parent inaccessible : local conservé (200)" \
    || echec "dossier parent inaccessible : local code $(code_local GET /api/orgue)"
  ERREUR=$(client_local GET /api/reseaux | champ erreur)
  [ -n "$ERREUR" ] && ok "dossier parent inaccessible : erreur publiée" \
    || echec "dossier parent inaccessible : aucune erreur publiée"
  arreter
  chmod 700 "$PROTEGE"
  rm -rf "$PROTEGE"
fi

arreter
echo
echo "== $OKS OK, $ECHECS échec(s), $IGNORES ignoré(s)"
[ "$ECHECS" -eq 0 ]
