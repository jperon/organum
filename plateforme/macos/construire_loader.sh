#!/bin/sh
# Construit le loader APE arm64 précompilé et signé, plateforme/macos/build/ape-m1-arm64.
#
# scripts/construire.sh s'en sert pour fusionner l'APE universel sans
# embarquer le source ape-m1.c : sur Apple Silicon, l'APE se déplie alors
# sans appeler cc et n'exige donc pas Xcode CLT au premier lancement.
#
# Le source plateforme/macos/ape-m1.c est la copie fidèle de
# cosmopolitan/ape/ape-m1.c (licence ISC, © Justine Tunney), figée au commit
# utilisé par scripts/dependances.sh. Il est embarqué ici pour que le job
# macOS de la CI n'ait pas besoin de construire cosmocc.
#
# macOS refuse d'exécuter un Mach-O arm64 non signé : la signature ad-hoc
# n'est pas facultative. apelink ne vérifie pas la signature du loader ; ce
# script la produit et la contrôle donc avant de publier le fichier.
#
# Usage : sh plateforme/macos/construire_loader.sh
set -eu

ici=$(cd "$(dirname "$0")" && pwd)
sortie="$ici/build/ape-m1-arm64"
source_c="$ici/ape-m1.c"

if ! command -v clang >/dev/null 2>&1; then
  echo "organum : clang introuvable ; le loader arm64 ne peut pas être compilé." >&2
  exit 2
fi
if ! command -v codesign >/dev/null 2>&1; then
  echo "organum : codesign introuvable ; un loader arm64 non signé serait inutilisable." >&2
  exit 2
fi
if ! command -v lipo >/dev/null 2>&1; then
  echo "organum : lipo introuvable ; impossible de vérifier l'architecture." >&2
  exit 2
fi
if [ ! -s "$source_c" ]; then
  echo "organum : source absente : $source_c" >&2
  exit 2
fi

mkdir -p "$ici/build"
tmp="$sortie.tmp.$$"
trap 'rm -f "$tmp"' EXIT INT TERM

# -mmacosx-version-min=11.0 est indispensable : sans lui, le loader prend le
# SDK de compilation comme cible et exige macOS 15 sur la machine cible.
clang -arch arm64 -O2 -w -mmacosx-version-min=11.0 -o "$tmp" "$source_c"

if ! codesign --force --sign - "$tmp"; then
  echo "organum : signature ad-hoc du loader impossible." >&2
  exit 3
fi
if ! codesign --verify --strict "$tmp" >/dev/null 2>&1; then
  echo "organum : la signature ad-hoc du loader ne se vérifie pas." >&2
  exit 3
fi
if ! codesign -dv "$tmp" >/dev/null 2>&1; then
  echo "organum : codesign -dv ne voit aucune signature sur le loader." >&2
  exit 3
fi

chmod 0755 "$tmp"
mv -f "$tmp" "$sortie"

echo "ape-m1-arm64 : architectures :"
lipo -info "$sortie"
echo "ape-m1-arm64 : signature ad-hoc :"
codesign -dv "$sortie" 2>&1

case " $(lipo -archs "$sortie") " in
  *" arm64 "*) ;;
  *)
    echo "organum : arm64 annoncé mais absent de $sortie" >&2
    exit 3
    ;;
esac

echo "ape-m1-arm64 : loader arm64 compilé : $sortie"
