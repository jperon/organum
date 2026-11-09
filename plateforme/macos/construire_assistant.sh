#!/bin/sh
# Construit les assistants natifs macOS : CoreMIDI et CoreAudio.
#
# Les assistants sont des binaires Mach-O hors de l'arbre cosmopolitan : ils
# ne sont pas produits par scripts/construire.sh, qui ne dispose pas des
# frameworks Apple. Ils se compilent sur un Mac avec les outils de
# développement Xcode.
#
# Usage :
#   sh plateforme/macos/construire_assistant.sh
#   ARCHIVES=1 sh plateforme/macos/construire_assistant.sh   # x86_64 + arm64
set -eu

ici=$(cd "$(dirname "$0")" && pwd)
sortie_midi="$ici/build/organum-midi"
sortie_audio="$ici/build/organum-audio"

if ! xcode-select -p >/dev/null 2>&1; then
  echo "organum : les outils de développement Xcode sont absents." >&2
  echo "organum : installez-les avec : xcode-select --install" >&2
  echo "organum : puis relancez ce script." >&2
  exit 2
fi

mkdir -p "$ici/build"

# ARCHIVES non vide : binaires universels Intel + Apple Silicon.
# shellcheck disable=SC2086
clang -std=c11 -O2 -Wall -Wextra -Wno-unused-parameter \
  ${ARCHIVES:+ -arch x86_64 -arch arm64} \
  -o "$sortie_midi" "$ici/assistant_coremidi.c" \
  -framework CoreMIDI -framework CoreFoundation

# shellcheck disable=SC2086
clang -std=c11 -O2 -Wall -Wextra -Wno-unused-parameter \
  ${ARCHIVES:+ -arch x86_64 -arch arm64} \
  -o "$sortie_audio" "$ici/assistant_audio.c" \
  -framework CoreAudio -framework AudioToolbox -framework CoreFoundation

chmod +x "$sortie_midi" "$sortie_audio" 2>/dev/null || true
echo "organum-midi : assistant compilé : $sortie_midi"
echo "organum-audio : assistant compilé : $sortie_audio"
