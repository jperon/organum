# Règles pures et boucle de mesure de cadence audio, partagées par :
#   - plateforme/macos/tests/valider_audio_midi.sh (CI Apple Silicon) ;
#   - web/scripts/test-audio-socket.sh (backend socket, sous Linux) ;
#   - plateforme/macos/tests/tester_cadence.sh (test local, sans macOS).
#
# L'écart est exprimé en points de base : 10000 = 100 %, 200 = 2 %.
# Un défaut structurel de cadence (facteur 1,5, horloge fausse, anneau mal
# drainé) donne des écarts de plusieurs milliers de points de base ; un pic de
# charge isolé sur un runner partagé en donne quelques centaines, et la
# médiane de trois fenêtres l'élimine. Le seuil reste donc à 2 % : ce sont la
# stabilisation, la médiane et le comptage des xruns en delta qui absorbent le
# bruit, jamais un élargissement de la tolérance.

# Tolérance par défaut, en points de base (2 %).
CADENCE_TOLERANCE_BP=${CADENCE_TOLERANCE_BP:-200}

# cadence_ecart_bp <jouees> <attendu> : écart absolu en points de base,
# ou -1 si la durée attendue est nulle (mesure impossible).
cadence_ecart_bp() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    if (b <= 0) { print -1; exit }
    d = a - b
    if (d < 0) d = -d
    printf "%.0f\n", d * 10000 / b
  }'
}

# cadence_attendues <nanosecondes> <taux> : trames attendues sur la durée.
cadence_attendues() {
  awk -v e="$1" -v t="$2" 'BEGIN {
    if (e < 0) e = 0
    printf "%.0f\n", e / 1000000000 * t
  }'
}

# cadence_mediane <a> <b> <c> : valeur médiane de trois entiers.
cadence_mediane() {
  printf '%s\n' "$1" "$2" "$3" | sort -n | sed -n '2p'
}

# cadence_mediane_liste <entiers...> : médiane d'une liste non vide.
cadence_mediane_liste() {
  printf '%s\n' "$@" | sort -n |
    awk '{ v[NR] = $1 } END {
      if (NR == 0) { print -1; exit }
      print v[int((NR + 1) / 2)]
    }'
}

# cadence_nombre <valeur> : entier utilisable, 0 si vide ou non numérique.
cadence_nombre() {
  case "$1" in
    ''|*[!0-9]*) printf '0\n' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# cadence_horloge_ns : horloge MONOTONE en nanosecondes. Un saut NTP ne doit
# pas fausser une durée. perl est fourni par macOS ; sous Linux, date +%s%N
# convient, mais on garde la même source des deux côtés quand c'est possible.
cadence_horloge_ns() {
  if [ "${CADENCE_SANS_PERL:-0}" != 1 ]; then
    _v=$(perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC -e \
      'printf "%.0f\n", clock_gettime(CLOCK_MONOTONIC) * 1000000000' \
      2>/dev/null) || _v=
    if [ -n "$_v" ]; then
      printf '%s\n' "$_v"
      return 0
    fi
    CADENCE_SANS_PERL=1
  fi
  date +%s%N
}

# cadence_fenetre <secondes> <lire_trames> <lire_xruns> [lire_invalide]
#
# Mesure une fenêtre et renseigne :
#   CADENCE_DEBUT_NS, CADENCE_FIN_NS, CADENCE_AVANT, CADENCE_APRES,
#   CADENCE_JOUEES, CADENCE_ATTENDU, CADENCE_BP,
#   CADENCE_XRUNS_AVANT, CADENCE_XRUNS_APRES, CADENCE_DELTA_XRUNS,
#   CADENCE_DELTA_INVALIDE.
#
# Les bornes de temps sont prises avant le premier getter et après le second,
# de sorte que la latence des requêtes HTTP s'annule. <lire_invalide> est un
# compteur monotone (par exemple le temps de lecture abandonné par un faux
# assistant) : tout incrément rend la fenêtre non interprétable.
cadence_fenetre() {
  _cf_duree=$1
  _cf_trames=$2
  _cf_xruns=$3
  _cf_invalide=${4:--}
  CADENCE_DEBUT_NS=$(cadence_horloge_ns)
  CADENCE_AVANT=$(cadence_nombre "$("$_cf_trames")")
  CADENCE_XRUNS_AVANT=$(cadence_nombre "$("$_cf_xruns")")
  CADENCE_INVALIDE_AVANT=0
  if [ "$_cf_invalide" != "-" ]; then
    CADENCE_INVALIDE_AVANT=$(cadence_nombre "$("$_cf_invalide")")
  fi
  sleep "$_cf_duree"
  CADENCE_FIN_NS=$(cadence_horloge_ns)
  CADENCE_APRES=$(cadence_nombre "$("$_cf_trames")")
  CADENCE_XRUNS_APRES=$(cadence_nombre "$("$_cf_xruns")")
  CADENCE_INVALIDE_APRES=0
  if [ "$_cf_invalide" != "-" ]; then
    CADENCE_INVALIDE_APRES=$(cadence_nombre "$("$_cf_invalide")")
  fi
  CADENCE_JOUEES=$((CADENCE_APRES - CADENCE_AVANT))
  [ "$CADENCE_JOUEES" -lt 0 ] && CADENCE_JOUEES=0
  CADENCE_ATTENDU=$(cadence_attendues \
    "$((CADENCE_FIN_NS - CADENCE_DEBUT_NS))" "$CADENCE_TAUX")
  CADENCE_BP=$(cadence_ecart_bp "$CADENCE_JOUEES" "$CADENCE_ATTENDU")
  CADENCE_DELTA_XRUNS=$((CADENCE_XRUNS_APRES - CADENCE_XRUNS_AVANT))
  [ "$CADENCE_DELTA_XRUNS" -lt 0 ] && CADENCE_DELTA_XRUNS=0
  CADENCE_DELTA_INVALIDE=$((CADENCE_INVALIDE_APRES - CADENCE_INVALIDE_AVANT))
  [ "$CADENCE_DELTA_INVALIDE" -lt 0 ] && CADENCE_DELTA_INVALIDE=0
}

# cadence_mesurer <nb_fenetres> <secondes> <taux> <lire_trames> <lire_xruns> \
#                  [lire_invalide] [max_essais]
#
# Mesure <nb_fenetres> fenêtres valides (3 par convention), puis juge la
# MÉDIANE des écarts contre CADENCE_TOLERANCE_BP. Une fenêtre dont le
# compteur d'invalidité a progressé, ou dont la durée est nulle, est rejetée
# et remplacée, dans la limite de <max_essais> (défaut : 2 × nb_fenetres).
# Renseigne CADENCE_OK, CADENCE_MEDIANE, CADENCE_BP_MESURES,
# CADENCE_XRUNS_TOTAL, CADENCE_FENETRES_XRUN, CADENCE_XRUNS_REFERENCE (compteur
# au début de la première fenêtre, donc après stabilisation), CADENCE_DETAIL.
cadence_mesurer() {
  _cm_nb=$1
  _cm_duree=$2
  CADENCE_TAUX=$3
  _cm_trames=$4
  _cm_xruns=$5
  _cm_invalide=${6:--}
  _cm_max=${7:-$((_cm_nb * 2))}
  _cm_bps=
  _cm_fait=0
  _cm_essai=0
  _cm_rejets=0
  CADENCE_XRUNS_TOTAL=0
  CADENCE_FENETRES_XRUN=0
  CADENCE_XRUNS_REFERENCE=
  while [ "$_cm_fait" -lt "$_cm_nb" ] && [ "$_cm_essai" -lt "$_cm_max" ]; do
    _cm_essai=$((_cm_essai + 1))
    cadence_fenetre "$_cm_duree" "$_cm_trames" "$_cm_xruns" "$_cm_invalide"
    if [ -z "$CADENCE_XRUNS_REFERENCE" ]; then
      CADENCE_XRUNS_REFERENCE=$CADENCE_XRUNS_AVANT
    fi
    if [ "$CADENCE_DELTA_INVALIDE" -gt 0 ]; then
      _cm_rejets=$((_cm_rejets + 1))
      echo "cadence : essai $_cm_essai rejeté (compteur d'invalidité +$CADENCE_DELTA_INVALIDE, fenêtre non interprétable)"
      continue
    fi
    if [ "$CADENCE_BP" -lt 0 ]; then
      _cm_rejets=$((_cm_rejets + 1))
      echo "cadence : essai $_cm_essai rejeté (durée nulle)"
      continue
    fi
    _cm_fait=$((_cm_fait + 1))
    _cm_bps="$_cm_bps $CADENCE_BP"
    CADENCE_XRUNS_TOTAL=$((CADENCE_XRUNS_TOTAL + CADENCE_DELTA_XRUNS))
    if [ "$CADENCE_DELTA_XRUNS" -gt 0 ]; then
      CADENCE_FENETRES_XRUN=$((CADENCE_FENETRES_XRUN + 1))
    fi
    echo "cadence : fenêtre $_cm_fait/$_cm_nb sur ${_cm_duree} s : $CADENCE_JOUEES trames pour $CADENCE_ATTENDU attendues (${CADENCE_BP}‱ d'écart), $CADENCE_DELTA_XRUNS xrun(s)"
  done
  CADENCE_BP_MESURES=$(printf '%s' "$_cm_bps" | sed 's/^ //')
  if [ "$_cm_fait" -lt "$_cm_nb" ]; then
    CADENCE_OK=0
    CADENCE_MEDIANE=-1
    CADENCE_DETAIL="$_cm_fait fenêtre(s) valide(s) sur $_cm_nb en $_cm_essai essai(s) ($_cm_rejets rejet(s)) : machine non stabilisée ou faux assistant trop chargé"
    return 1
  fi
  # shellcheck disable=SC2086
  CADENCE_MEDIANE=$(cadence_mediane_liste $_cm_bps)
  if [ "$CADENCE_MEDIANE" -le "$CADENCE_TOLERANCE_BP" ]; then
    CADENCE_OK=1
  else
    CADENCE_OK=0
  fi
  CADENCE_DETAIL="médiane ${CADENCE_MEDIANE}‱ sur $_cm_fait fenêtres de ${_cm_duree} s (mesures : $CADENCE_BP_MESURES ; $_cm_rejets rejet(s)), $CADENCE_XRUNS_TOTAL xrun(s) dans $CADENCE_FENETRES_XRUN fenêtre(s)"
  [ "$CADENCE_OK" -eq 1 ]
}

# cadence_xruns_ok <total> <fenetres_touchees> : un pic isolé dans une seule
# fenêtre est un accident d'ordonnancement, pas un régime d'underruns ; deux
# fenêtres touchées ou plus, ou un seul xrun continu, restent une erreur.
cadence_xruns_ok() {
  [ "$1" -eq 0 ] && return 0
  [ "$2" -le 1 ] && return 0
  return 1
}

# cadence_xruns_texte <total> <fenetres_touchees> <reference> <apres>
cadence_xruns_texte() {
  if [ "$1" -eq 0 ]; then
    printf 'aucun nouvel xrun pendant la mesure (référence %s, total %s)\n' "$3" "$4"
  elif [ "$2" -le 1 ]; then
    printf '%s xrun(s) dans %s fenêtre(s) sur la mesure : pic isolé d\047ordonnancement (référence %s, total %s)\n' "$1" "$2" "$3" "$4"
  else
    printf '%s nouvel(x) xrun(s) dans %s fenêtre(s) : régime d\047underruns (référence %s, total %s)\n' "$1" "$2" "$3" "$4"
  fi
}
