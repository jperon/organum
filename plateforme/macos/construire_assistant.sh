#!/bin/sh
# Construit l'assistant CoreMIDI natif pour macOS.
#
# L'assistant est un binaire Mach-O hors de l'arbre cosmopolitan : il n'est
# pas produit par scripts/construire.sh, qui ne dispose pas des frameworks
# Apple. Il se compile sur un Mac avec les outils de développement Xcode.
#
# Usage :
#   sh plateforme/macos/construire_assistant.sh
#   ARCHIVES=1 sh plateforme/macos/construire_assistant.sh   # x86_64 + arm64
set -eu

ici=$(cd "$(dirname "$0")" && pwd)
sortie="$ici/build/organum-midi"

if ! xcode-select -p >/dev/null 2>&1; then
  echo "organum-midi : les outils de développement Xcode sont absents." >&2
  echo "organum-midi : installez-les avec : xcode-select --install" >&2
  echo "organum-midi : puis relancez ce script." >&2
  exit 2
fi

mkdir -p "$ici/build"

# ARCHIVES non vide : binaire universel Intel + Apple Silicon.
# shellcheck disable=SC2086
clang -std=c11 -O2 -Wall -Wextra -Wno-unused-parameter \
  ${ARCHIVES:+ -arch x86_64 -arch arm64} \
  -o "$sortie" "$ici/assistant_coremidi.c" \
  -framework CoreMIDI -framework CoreFoundation

chmod +x "$sortie" 2>/dev/null || true
echo "organum-midi : assistant compilé : $sortie"
