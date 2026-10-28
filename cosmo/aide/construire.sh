#!/bin/sh
# Construit dlopen-helper-glibc-x86_64, embarqué dans organum.com puis
# installé dans ~/.cosmo s'il y manque (voir web/src/init.moon).
set -e
cd "$(dirname "$0")"
cc -O2 -pie -fPIC -nostartfiles -fno-stack-protector -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0 -include versions-glibc.h \
  dlopen-helper.c -o dlopen-helper-glibc-x86_64 -Wl,-z,execstack -ldl
strip dlopen-helper-glibc-x86_64
# Garde-fou : aucune version de glibc postérieure à 2.2.5.
if objdump -T dlopen-helper-glibc-x86_64 | grep -o 'GLIBC_[0-9.]*' | grep -vx 'GLIBC_2.2.5'; then
  echo "versions de glibc trop récentes ci-dessus" >&2
  exit 1
fi

# Variante musl (Alpine, Void musl…) : musl n'a pas de versions de symboles.
if command -v musl-gcc >/dev/null; then
  musl-gcc -O2 -pie -fPIC dlopen-helper.c -o dlopen-helper-musl-x86_64 -Wl,-z,execstack
  strip dlopen-helper-musl-x86_64
else
  echo "musl-gcc absent : programme d'aide musl non construit" >&2
fi
