#!/bin/sh
# Test local des règles de mesure de cadence de valider_audio_midi.sh, sans
# macOS, sans serveur et sans carte son. Il prouve que le contrôle retenu :
#   - accepte une cadence correcte, même avec un pic de charge isolé ;
#   - refuse un défaut STRUCTUREL (facteur 1,5, facteur 0,5, horloge à
#     +85 %), quel que soit le bruit de mesure.
# Usage : sh plateforme/macos/tests/tester_cadence.sh
set -u

ICI=$(cd "$(dirname "$0")" && pwd)
. "$ICI/cadence.sh"

TOLERANCE_BP=200
echecs=0

ok() { echo "OK : $*"; }
echec() {
  echo "ÉCHEC : $*"
  echecs=$((echecs + 1))
}

verifie() { # verifie <description> <attendu> <reçu>
  if [ "$2" = "$3" ]; then
    ok "$1 ($3)"
  else
    echec "$1 : attendu $2, reçu $3"
  fi
}

verifie_verdict() { # verifie_verdict <description> <passe|echoue> <a> <b> <c>
  mediane=$(cadence_mediane "$3" "$4" "$5")
  if [ "$mediane" -le "$TOLERANCE_BP" ]; then
    verdict=passe
  else
    verdict=echoue
  fi
  if [ "$2" = "$verdict" ]; then
    ok "$1 : médiane ${mediane}‱ → $verdict"
  else
    echec "$1 : médiane ${mediane}‱ → $verdict, attendu $2"
  fi
}

# --- Formule d'écart ------------------------------------------------------
# Mesure réelle du run 42653100117 : 151040 trames pour 149263 attendues.
verifie "écart de la mesure réelle (~1,2 %)" 119 \
  "$(cadence_ecart_bp 151040 149263)"
verifie "absence totale de trames" 10000 "$(cadence_ecart_bp 0 48000)"
verifie "durée nulle refusée" -1 "$(cadence_ecart_bp 48000 0)"

# --- Médiane --------------------------------------------------------------
verifie "médiane de [236, 80, 120]" 120 "$(cadence_mediane 236 80 120)"
verifie "médiane de [120, 236, 80]" 120 "$(cadence_mediane 120 236 80)"
verifie "médiane de [5000, 5000, 5000]" 5000 \
  "$(cadence_mediane 5000 5000 5000)"

# --- Charge normale, avec ou sans pic -------------------------------------
verifie_verdict "cadence nominale" passe 119 87 95
verifie_verdict "pic de charge isolé (2,36 % observé)" passe 236 80 120
verifie_verdict "pic plus marqué sur une fenêtre" passe 600 30 20

# --- Défauts structurels : les trois fenêtres sont fausses ---------------
# Facteur 1,5 : 720000 trames pour 480000 attendues → 50 % d'écart.
pct=$(cadence_ecart_bp 720000 480000)
verifie "facteur 1,5 donne 50 % d'écart" 5000 "$pct"
verifie_verdict "facteur 1,5 détecté" echoue "$pct" "$pct" "$pct"

# Facteur 0,5 : 240000 trames pour 480000 attendues → 50 % d'écart.
pct=$(cadence_ecart_bp 240000 480000)
verifie "facteur 0,5 donne 50 % d'écart" 5000 "$pct"
verifie_verdict "facteur 0,5 détecté" echoue "$pct" "$pct" "$pct"

# Horloge fausse mesurée sur VM XNU : ~85 % d'écart.
pct=$(cadence_ecart_bp 888000 480000)
verifie_verdict "horloge à +85 % détectée" echoue "$pct" "$pct" "$pct"

if [ "$echecs" -ne 0 ]; then
  echo "ÉCHEC : $echecs contrôle(s) en échec" >&2
  exit 1
fi
echo "règles de cadence audio : OK"
