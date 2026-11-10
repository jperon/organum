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
verifie "médiane de liste [236, 80, 120]" 120 \
  "$(cadence_mediane_liste 236 80 120)"

# --- Trames attendues ------------------------------------------------------
verifie "3 s à 48 kHz" 144000 "$(cadence_attendues 3000000000 48000)"
verifie "durée nulle" 0 "$(cadence_attendues 0 48000)"

# --- Verdict des xruns : un pic isolé, jamais un régime -------------------
if cadence_xruns_ok 0 0; then ok "aucun xrun toléré"; else echec "aucun xrun refusé"; fi
if cadence_xruns_ok 1024 1; then ok "pic de 1024 xruns dans 1 fenêtre toléré"; else echec "pic isolé refusé"; fi
if cadence_xruns_ok 1024 2; then echec "xruns dans 2 fenêtres tolérés"; else ok "xruns dans 2 fenêtres refusés"; fi
verifie "texte d'un pic isolé" \
  "1024 xrun(s) dans 1 fenêtre(s) sur la mesure : pic isolé d'ordonnancement (référence 0, total 1024)" \
  "$(cadence_xruns_texte 1024 1 0 1024)"

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

# --- Boucle de mesure : médiane, rejet, défaut structurel -----------------
# Horloge et compteurs remplacés par des fichiers : une fenêtre simulée dure
# exactement 1 s et produit ESSAI_PAS trames. Aucun sommeil réel.
TMP_ESSAI=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP_ESSAI"' EXIT INT TERM
essai_init() {
  printf '0\n' > "$TMP_ESSAI/horloge"
  printf '0\n' > "$TMP_ESSAI/trames"
  printf '0\n' > "$TMP_ESSAI/xruns"
  printf '0\n' > "$TMP_ESSAI/invalide"
  ESSAI_PAS=${1:-48000}
}
essai_lire_ajoute() { # fichier pas
  _n=$(cat "$TMP_ESSAI/$1")
  _n=$((_n + $2))
  printf '%s\n' "$_n" > "$TMP_ESSAI/$1"
  printf '%s\n' "$_n"
}
essai_horloge() { essai_lire_ajoute horloge 1000000000; }
essai_trames() { essai_lire_ajoute trames "$ESSAI_PAS"; }
essai_xruns() { cat "$TMP_ESSAI/xruns"; }
essai_invalide() { cat "$TMP_ESSAI/invalide"; }
essai_invalide_croissant() { essai_lire_ajoute invalide 1; }
# La boucle appelle cadence_horloge_ns : on la remplace par l'horloge simulée.
cadence_horloge_ns() { essai_horloge; }

essai_init 48000
if cadence_mesurer 3 0 48000 essai_trames essai_xruns - 6 >/dev/null; then
  verifie "boucle : cadence nominale acceptée" 0 "$CADENCE_MEDIANE"
else
  echec "boucle : cadence nominale refusée ($CADENCE_DETAIL)"
fi

# Facteur 1,5 : chaque fenêtre donne 50 % d'écart, la médiane aussi.
essai_init 72000
if cadence_mesurer 3 0 48000 essai_trames essai_xruns - 6 >/dev/null; then
  echec "boucle : facteur 1,5 accepté (défaut non détecté)"
else
  verifie "boucle : facteur 1,5 détecté" 5000 "$CADENCE_MEDIANE"
fi

# Une fenêtre non interprétable est remplacée ; au-delà du plafond, échec.
essai_init 48000
if cadence_mesurer 3 0 48000 essai_trames essai_xruns essai_invalide_croissant 4 >/dev/null; then
  echec "boucle : fenêtres invalides acceptées"
else
  verifie "boucle : rejets exhaustifs signalés" -1 "$CADENCE_MEDIANE"
fi

if [ "$echecs" -ne 0 ]; then
  echo "ÉCHEC : $echecs contrôle(s) en échec" >&2
  exit 1
fi
echo "règles de cadence audio : OK"
