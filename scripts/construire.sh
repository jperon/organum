#!/usr/bin/env bash
# Construit organum.com de bout en bout : dépendances, moteur, exécutable
# (dans l'arbre cosmopolitan), puis interface web. Résultat : web/build/organum.com
#
# Par défaut, produit un APE universel x86-64 + arm64 quand l'outillage
# aarch64 est disponible : moteur et organum pour les deux architectures,
# puis fusion avec apelink. Le loader arm64 préconstruit et signé
# plateforme/macos/build/ape-m1-arm64 évite toute compilation au premier
# lancement sur Apple Silicon ; à défaut, ape/ape-m1.c est embarqué (le
# binaire exigera alors Xcode CLT au premier lancement).
#
# Variables :
#   JOBS               parallélisme (défaut nproc)
#   ORGANUM_UNIVERSEL  0 : ancien comportement, APE x86-64 seulement
#   ORGANUM_LOADER_ARM64  autre chemin du loader arm64 préconstruit
#
# Si l'outillage aarch64 manque ou si sa construction échoue, le script
# continue et produit l'APE x86-64 comme avant : l'aarch64 ne fait jamais
# échouer la construction.
set -euo pipefail

RACINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JOBS="${JOBS:-$(nproc)}"
UNIVERSEL="${ORGANUM_UNIVERSEL:-1}"
ORGANUM_X86="$RACINE/externe/cosmopolitan/o//tool/organum/organum"
APE_UNIVERSEL=""
ORGANUM_RETENU=""

"$RACINE/scripts/dependances.sh"

echo "== programmes d'aide de cosmo_dlopen"
"$RACINE/cosmo/aide/construire.sh"

echo "== moteur (x86-64)"
make -C "$RACINE/moteur" -j"$JOBS"

echo "== organum (redbean + moteur, x86-64)"
make -C "$RACINE/externe/cosmopolitan" -j"$JOBS" m= o//tool/organum/organum

# Construit la moitié aarch64 et fusionne les deux APE.
# Rend 0 seulement si web/build/organum-universel.com a été produit.
construire_universel() {
  local cosmo="$RACINE/externe/cosmocc"
  local c="$RACINE/externe/cosmopolitan"
  local moteur_aarch64="$RACINE/moteur/libaeolus-aarch64.a"
  local out="$RACINE/web/build/organum-universel.com"
  local x86_dbg="$RACINE/externe/cosmopolitan/o//tool/organum/organum.dbg"
  local arm_dbg="$RACINE/externe/cosmopolitan/o/aarch64/tool/organum/organum.dbg"
  local loader_x86 loader_arm loader_m1 source_m1

  if [ ! -x "$cosmo/bin/aarch64-unknown-cosmo-c++" ] ||
     [ ! -s "$cosmo/aarch64-linux-cosmo/lib/libcosmo.a" ] ||
     [ ! -x "$cosmo/bin/apelink" ]; then
    echo "avertissement : outillage aarch64 incomplet dans $cosmo" >&2
    echo "avertissement : repli sur organum.com x86-64 seulement" >&2
    return 1
  fi

  loader_x86="$cosmo/bin/ape-x86_64.elf"
  [ -s "$loader_x86" ] || loader_x86="$c/o/x86_64/ape/ape.elf"
  loader_arm="$cosmo/bin/ape-aarch64.elf"
  [ -s "$loader_arm" ] || loader_arm="$c/o/aarch64/ape/ape.elf"
  loader_m1="${ORGANUM_LOADER_ARM64:-$RACINE/plateforme/macos/build/ape-m1-arm64}"
  source_m1="$c/ape/ape-m1.c"
  [ -s "$source_m1" ] || source_m1="$cosmo/bin/ape-m1.c"

  if [ ! -s "$loader_x86" ] || [ ! -s "$loader_arm" ]; then
    echo "avertissement : loaders APE x86-64 ou aarch64 absents" >&2
    echo "avertissement : repli sur organum.com x86-64 seulement" >&2
    return 1
  fi

  echo "== moteur (aarch64)"
  make -C "$RACINE/moteur" -j"$JOBS" ARCH=aarch64 || return 1

  echo "== organum (redbean + moteur, aarch64)"
  make -C "$c" -j"$JOBS" m=aarch64 ORGANUM_MOTEUR="$moteur_aarch64" \
    o/aarch64/tool/organum/organum || return 1

  if [ ! -s "$x86_dbg" ] || [ ! -s "$arm_dbg" ]; then
    echo "avertissement : exécutables de débogage absents pour la fusion" >&2
    return 1
  fi

  local args=(-l "$loader_x86" -l "$loader_arm")
  if [ -s "$loader_m1" ]; then
    echo "== fusion APE universel (loader arm64 préconstruit : $loader_m1)"
    args+=(-l "$loader_m1")
  else
    echo "avertissement : $loader_m1 absent ; ape/ape-m1.c sera embarqué." >&2
    echo "avertissement : le binaire exigera Xcode CLT au premier lancement sur Apple Silicon." >&2
    echo "avertissement : placez plateforme/macos/build/ape-m1-arm64 (construire_assistant.sh)" >&2
    echo "avertissement : pour un lancement sans compilateur." >&2
    if [ ! -s "$source_m1" ]; then
      echo "avertissement : source ape-m1.c introuvable ; fusion impossible" >&2
      return 1
    fi
    args+=(-M "$source_m1")
  fi

  mkdir -p "$RACINE/web/build"
  rm -f "$out.tmp"
  "$cosmo/bin/apelink" "${args[@]}" -o "$out.tmp" "$x86_dbg" "$arm_dbg" || return 1
  mv -f "$out.tmp" "$out"
  echo "APE universel : $out ($(du -h "$out" | cut -f1))"
  APE_UNIVERSEL="$out"
  return 0
}

if [ "$UNIVERSEL" != 0 ]; then
  if construire_universel; then
    ORGANUM_RETENU="$APE_UNIVERSEL"
  else
    echo "avertissement : APE universel indisponible ; organum.com sera x86-64 seulement" >&2
  fi
else
  echo "== APE universel désactivé (ORGANUM_UNIVERSEL=0)"
fi

if [ -z "$ORGANUM_RETENU" ]; then
  ORGANUM_RETENU="$ORGANUM_X86"
fi

echo "== interface web"
ORGANUM="$ORGANUM_RETENU" "$RACINE/web/scripts/build.sh"

if [ "${ORGANUM_TESTS:-0}" = 1 ]; then
	"$RACINE/scripts/tester.sh"
fi
