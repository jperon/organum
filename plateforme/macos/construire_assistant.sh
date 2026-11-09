#!/bin/sh
# Construit l'assistant natif macOS : CoreMIDI et CoreAudio dans un seul
# binaire, organum-helper.
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
sortie="$ici/build/organum-helper"

if ! xcode-select -p >/dev/null 2>&1; then
  echo "organum : les outils de développement Xcode sont absents." >&2
  echo "organum : installez-les avec : xcode-select --install" >&2
  echo "organum : puis relancez ce script." >&2
  exit 2
fi

mkdir -p "$ici/build"

# ARCHIVES non vide : binaire universel Intel + Apple Silicon.
# shellcheck disable=SC2086
clang -std=c11 -O2 -Wall -Wextra \
  ${ARCHIVES:+ -arch x86_64 -arch arm64} \
  -o "$sortie" "$ici/assistant_helper.c" \
  -framework CoreMIDI -framework CoreAudio -framework AudioToolbox \
  -framework CoreFoundation

chmod +x "$sortie" 2>/dev/null || true
echo "organum-helper : assistant compilé : $sortie"
