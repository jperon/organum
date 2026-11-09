# Règles pures de la mesure de cadence audio, partagées par
# valider_audio_midi.sh (CI Apple Silicon) et tester_cadence.sh (test local,
# sans macOS ni carte son).
#
# L'écart est exprimé en points de base : 10000 = 100 %, 200 = 2 %.
# Un défaut structurel de cadence (facteur 1,5, horloge fausse, anneau
# mal drainé) donne des écarts de plusieurs milliers de points de base ; un
# pic de charge isolé sur un runner partagé en donne quelques centaines, et
# la médiane de plusieurs fenêtres l'élimine.

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

# cadence_mediane <a> <b> <c> : valeur médiane de trois entiers.
cadence_mediane() {
  printf '%s\n' "$1" "$2" "$3" | sort -n | sed -n '2p'
}
