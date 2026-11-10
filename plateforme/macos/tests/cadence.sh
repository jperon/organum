# Emplacement historique : les règles et la boucle de mesure de cadence sont
# désormais partagées par tous les scripts, y compris le test socket Linux.
# Ce fichier ne contient plus que le renvoi, pour ne pas casser un appel
# existant.
ICI_CADENCE=$(cd "$(dirname "$0")" && pwd)
. "$ICI_CADENCE/../../tests/cadence.sh"
