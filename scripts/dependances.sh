#!/usr/bin/env bash
# Prépare les dépendances externes dans externe/ (ignoré par git) :
#   externe/cosmopolitan  arbre cosmopolitan à un commit fixe, corrigé par
#                         cosmo/cosmopolitan.patch, avec tool/organum -> cosmo/
#   externe/cosmocc       chaîne cosmocc construite depuis cet arbre
#   externe/JUCE          JUCE au commit utilisé par le greffon Aeolus
# Un dossier déjà présent (ou un lien vers une copie existante) est conservé.
set -euo pipefail

COSMOPOLITAN_COMMIT=aefad27c09ffda64c6ac64bd69f758e9f9c7b91d
JUCE_COMMIT=10a589619b452c261b2940767eb253171eb5a823

RACINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXTERNE="$RACINE/externe"
mkdir -p "$EXTERNE"

# Clone superficiel d'un unique commit.
cloner() {  # url commit dossier
  git init -q "$3"
  git -C "$3" fetch -q --depth 1 "$1" "$2"
  git -C "$3" checkout -q FETCH_HEAD
}

if [ ! -e "$EXTERNE/JUCE" ]; then
  echo "== JUCE"
  cloner https://github.com/juce-framework/JUCE.git "$JUCE_COMMIT" "$EXTERNE/JUCE"
fi

C="$EXTERNE/cosmopolitan"
if [ ! -e "$C" ]; then
  echo "== cosmopolitan"
  cloner https://github.com/jart/cosmopolitan.git "$COSMOPOLITAN_COMMIT" "$C"
  git -C "$C" apply "$RACINE/cosmo/cosmopolitan.patch"
fi
[ -e "$C/tool/organum" ] || ln -s "$RACINE/cosmo" "$C/tool/organum"

if [ ! -x "$EXTERNE/cosmocc/bin/cosmoc++" ]; then
  echo "== cosmocc (long : construit toute la libc pour x86-64 et aarch64)"
  (cd "$C" && tool/cosmocc/package.sh "$EXTERNE/cosmocc")
fi
