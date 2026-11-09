#!/bin/sh
# Construit dlopen-helper-glibc-x86_64, embarqué dans organum.com puis
# installé dans ~/.cosmo s'il y manque (voir web/src/init.moon).
set -e
cd "$(dirname "$0")"
# -std=gnu11 : à partir de GCC 15 / C23, les en-têtes de la glibc 2.38+
# redirigent strtol vers __isoc23_strtol@GLIBC_2.38, que les .symver de
# versions-glibc.h ne couvrent pas et qui rendrait l'aide inutilisable sur
# une glibc plus ancienne. Le C11 garde les noms historiques des symboles.
cc -std=gnu11 -O2 -pie -fPIC -nostartfiles -fno-stack-protector -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0 -include versions-glibc.h \
  dlopen-helper.c -o dlopen-helper-glibc-x86_64 -Wl,-z,execstack -ldl
strip dlopen-helper-glibc-x86_64
# Garde-fou : aucune version de glibc postérieure à 2.2.5.
TROP_RECENTES=$(objdump -T dlopen-helper-glibc-x86_64 | grep -o 'GLIBC_[0-9.]*' | grep -vx 'GLIBC_2.2.5' | sort -u || true)
if [ -n "$TROP_RECENTES" ]; then
  printf 'ERREUR : le programme d\047aide référence des versions de glibc trop récentes :\n%s\n' "$TROP_RECENTES" >&2
  echo "Ajouter le .symver correspondant dans cosmo/aide/versions-glibc.h" >&2
  echo "(ou compiler avec une option qui évite la redirection C23)." >&2
  exit 1
fi

# Variante musl (Alpine, Void musl…) : musl n'a pas de versions de symboles.
if command -v musl-gcc >/dev/null; then
  musl-gcc -std=gnu11 -O2 -pie -fPIC dlopen-helper.c -o dlopen-helper-musl-x86_64 -Wl,-z,execstack
  strip dlopen-helper-musl-x86_64
else
  echo "musl-gcc absent : programme d'aide musl non construit" >&2
fi
