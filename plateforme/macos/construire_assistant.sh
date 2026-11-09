#!/bin/sh
# Construit l'assistant natif macOS : CoreMIDI et CoreAudio dans un seul
# binaire, organum-helper.
#
# L'assistant est un binaire Mach-O hors de l'arbre cosmopolitan : il n'est
# pas produit par scripts/construire.sh, qui ne dispose pas des frameworks
# Apple. Il se compile sur un Mac avec les outils de développement Xcode.
#
# Le binaire est universel par défaut (x86_64 + arm64) quand le SDK fournit
# les deux architectures, sinon limité à l'architecture de l'hôte avec un
# message explicite. Il est toujours signé ad-hoc : macOS arm64 refuse
# d'exécuter un Mach-O non signé, même sans compte de développeur.
#
# Usage :
#   sh plateforme/macos/construire_assistant.sh              # universel
#   ARCHIVES=0 sh plateforme/macos/construire_assistant.sh   # hôte seul
#   ARCHIVES=1 sh plateforme/macos/construire_assistant.sh   # universel
set -eu

ici=$(cd "$(dirname "$0")" && pwd)
sortie="$ici/build/organum-helper"
source_c="$ici/assistant_helper.c"

if ! xcode-select -p >/dev/null 2>&1; then
  echo "organum : les outils de développement Xcode sont absents." >&2
  echo "organum : installez-les avec : xcode-select --install" >&2
  echo "organum : puis relancez ce script." >&2
  exit 2
fi

if ! command -v clang >/dev/null 2>&1; then
  echo "organum : clang introuvable malgré Xcode ; vérifiez xcode-select -p." >&2
  exit 2
fi
if ! command -v codesign >/dev/null 2>&1; then
  echo "organum : codesign introuvable ; la signature ad-hoc est obligatoire." >&2
  echo "organum : un binaire arm64 non signé serait inutilisable." >&2
  exit 2
fi
if ! command -v lipo >/dev/null 2>&1; then
  echo "organum : lipo introuvable ; impossible de vérifier les architectures." >&2
  exit 2
fi

hote=$(uname -m)
case "$hote" in
  x86_64) autre=arm64 ;;
  arm64) autre=x86_64 ;;
  *)
    echo "organum : architecture d'hôte inconnue : $hote" >&2
    exit 2
    ;;
esac

mkdir -p "$ici/build"

# Sonde une architecture en compilant réellement la source : un SDK peut
# annoncer une architecture et manquer des en-têtes ou des frameworks.
sonde() {
  clang -std=c11 -O2 -arch "$1" -c -o "$ici/build/sonde-$1.o" "$source_c" \
    >/dev/null 2>&1
}

supporte_hote=0
supporte_autre=0
if sonde "$hote"; then supporte_hote=1; fi
if sonde "$autre"; then supporte_autre=1; fi
rm -f "$ici/build/sonde-$hote.o" "$ici/build/sonde-$autre.o"

if [ "$supporte_hote" != 1 ]; then
  echo "organum : cette machine ne peut pas compiler pour son architecture ($hote)." >&2
  echo "organum : vérifiez l'installation de Xcode (xcode-select -p, SDK)." >&2
  exit 2
fi

universel=0
if [ "${ARCHIVES:-1}" != 0 ] && [ "$supporte_autre" = 1 ]; then
  universel=1
  architectures="-arch x86_64 -arch arm64"
elif [ "${ARCHIVES:-1}" != 0 ]; then
  echo "organum : le SDK ne fournit pas l'architecture $autre ; binaire limité à $hote." >&2
  echo "organum : pour un binaire universel, installez un SDK complet (Xcode)." >&2
  architectures="-arch $hote"
else
  architectures="-arch $hote"
fi

# shellcheck disable=SC2086
clang -std=c11 -O2 -Wall -Wextra $architectures \
  -o "$sortie" "$source_c" \
  -framework CoreMIDI -framework CoreAudio -framework AudioToolbox \
  -framework CoreFoundation

chmod +x "$sortie" 2>/dev/null || true

# Signature ad-hoc : indispensable sous arm64, inoffensive sous Intel. Un
# binaire tiré d'un zip et non signé est refusé par le noyau Apple Silicon.
if ! codesign --force --sign - "$sortie"; then
  echo "organum : signature ad-hoc impossible : $sortie" >&2
  echo "organum : un binaire arm64 non signé serait inutilisable." >&2
  exit 3
fi
if ! codesign --verify --strict "$sortie" >/dev/null 2>&1; then
  echo "organum : la signature ad-hoc ne se vérifie pas : $sortie" >&2
  exit 3
fi
if ! codesign -dv "$sortie" >/dev/null 2>&1; then
  echo "organum : codesign -dv ne voit aucune signature : $sortie" >&2
  exit 3
fi

# Preuve publiée dans le journal de construction.
echo "organum-helper : architectures :"
lipo -info "$sortie"
echo "organum-helper : signature ad-hoc :"
codesign -dv "$sortie" 2>&1

archs=$(lipo -archs "$sortie")
if [ "$universel" = 1 ]; then
  case " $archs " in
    *" x86_64 "*) ;;
    *)
      echo "organum : arm64 annoncé mais x86_64 absent de $sortie ($archs)." >&2
      exit 3
      ;;
  esac
  case " $archs " in
    *" arm64 "*) ;;
    *)
      echo "organum : arm64 annoncé mais absent de $sortie ($archs)." >&2
      exit 3
      ;;
  esac
else
  case " $archs " in
    *" $hote "*) ;;
    *)
      echo "organum : $hote annoncé mais absent de $sortie ($archs)." >&2
      exit 3
      ;;
  esac
fi

echo "organum-helper : assistant compilé : $sortie"
