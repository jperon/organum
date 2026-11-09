#!/usr/bin/env bash
# Prépare les dépendances externes dans externe/ (ignoré par git) :
#   externe/cosmopolitan  arbre cosmopolitan à un commit fixe, corrigé par
#                         cosmo/cosmopolitan.patch, avec tool/organum -> cosmo/
#   externe/cosmocc       chaîne cosmocc construite depuis cet arbre
#   externe/JUCE          JUCE au commit utilisé par le greffon Aeolus
# Un dossier déjà présent (ou un lien vers une copie existante) est conservé.
set -euo pipefail

COSMOPOLITAN_COMMIT=675370ee428bf48b77b22383679fcb9294d55fdb
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
  cloner https://github.com/jperon/cosmopolitan.git "$COSMOPOLITAN_COMMIT" "$C"
  git -C "$C" apply "$RACINE/cosmo/cosmopolitan.patch"
fi
[ -e "$C/tool/organum" ] || ln -s "$RACINE/cosmo" "$C/tool/organum"

if [ ! -x "$EXTERNE/cosmocc/bin/cosmoc++" ]; then
  echo "== cosmocc (long : construit toute la libc pour x86-64 et aarch64)"
  (cd "$C" && tool/cosmocc/package.sh "$EXTERNE/cosmocc")
fi

# Complète l'état aarch64 de cosmocc.
#
# Selon la façon dont la chaîne a été obtenue (paquet déjà constitué, copie
# d'une installation existante, ou paquet construit avant que l'arbre
# cosmopolitan ne fournisse les objets aarch64), il arrive que cosmocc
# contienne les compilateurs croisés aarch64 mais pas le dossier
# aarch64-linux-cosmo/lib. Sans lui, aarch64-unknown-cosmo-c++ échoue au lien
# et scripts/construire.sh ne peut pas produire l'APE universel.
#
# Les objets nécessaires existent déjà dans l'arbre cosmopolitan
# (o/aarch64/) : on les recopie sous les noms attendus par cosmocross, avec
# les mêmes stubs d'archives vides que tool/cosmocc/package.sh. La fonction
# est idempotente : un fichier déjà présent n'est jamais remplacé, donc une
# installation correcte n'est pas modifiée.
completer_aarch64() {
  cosmo="$EXTERNE/cosmocc"
  obj="$C/o/aarch64"
  lib="$cosmo/aarch64-linux-cosmo/lib"
  poser() {  # source destination
    [ -e "$2" ] || cp -f "$1" "$2"
  }

  # Déjà complet : ne rien toucher.
  if [ -s "$lib/libcosmo.a" ] && [ -s "$lib/libcxx.a" ] &&
     [ -s "$lib/crt.o" ] && [ -s "$lib/aarch64.lds" ] &&
     [ -s "$cosmo/bin/ape-aarch64.elf" ]; then
    return 0
  fi

  # Les objets peuvent manquer dans un arbre tout neuf ou incomplet : on
  # demande à make de les produire, sans reconstruire ce qui existe déjà.
  if [ ! -s "$obj/cosmopolitan.a" ] || [ ! -s "$obj/third_party/libcxx/libcxx.a" ] ||
     [ ! -s "$obj/libc/crt/crt.o" ] || [ ! -s "$obj/ape/aarch64.lds" ] ||
     [ ! -s "$obj/ape/ape.elf" ]; then
    echo "== objets aarch64 de cosmopolitan (pour compléter cosmocc)"
    if ! make -C "$C" -j"${JOBS:-$(nproc)}" m=aarch64         o/aarch64/cosmopolitan.a         o/aarch64/third_party/libcxx/libcxx.a         o/aarch64/libc/crt/crt.o         o/aarch64/libc/crt/crtfastmath.o         o/aarch64/ape/aarch64.lds         o/aarch64/ape/ape.elf >&2; then
      echo "avertissement : objets aarch64 indisponibles ; cosmocc reste x86-64." >&2
      return 0
    fi
  fi

  mkdir -p "$lib" "$cosmo/bin"
  poser "$obj/cosmopolitan.a" "$lib/libcosmo.a"
  poser "$obj/third_party/libcxx/libcxx.a" "$lib/libcxx.a"
  poser "$obj/libc/crt/crt.o" "$lib/crt.o"
  [ -s "$obj/libc/crt/crtfastmath.o" ] &&
    poser "$obj/libc/crt/crtfastmath.o" "$lib/crtfastmath.o"
  poser "$obj/ape/aarch64.lds" "$lib/aarch64.lds"
  poser "$obj/ape/ape.elf" "$cosmo/bin/ape-aarch64.elf"

  # Archives vides : cosmocross les ajoute toujours à la ligne de lien, même
  # quand tout vient de libcosmo.a. Même contenu que package.sh.
  for stub in c dl gcc_s m crypt pthread resolv rt unwind gomp stdc++; do
    [ -e "$lib/lib$stub.a" ] ||
      printf '!<arch>\n' >"$lib/lib$stub.a"
  done

  if [ -s "$lib/libcosmo.a" ] && [ -s "$lib/libcxx.a" ] &&
     [ -s "$lib/crt.o" ] && [ -s "$cosmo/bin/ape-aarch64.elf" ]; then
    echo "== état aarch64 de cosmocc complété ($lib)"
  else
    echo "avertissement : état aarch64 de cosmocc incomplet ; repli x86-64." >&2
  fi
}

completer_aarch64
