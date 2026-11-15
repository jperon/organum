/* La fortification de la glibc (glibc 2.38+) redirige fprintf vers
   __fprintf_chk@GLIBC_2.3.4. Le cc de certains systèmes (NixOS) l'impose
   après nos options, malgré -D_FORTIFY_SOURCE=0 : on l'annule ici, avant le
   premier en-tête, pour que le programme d'aide n'utilise que des symboles
   liés à GLIBC_2.2.5 (contrôle en fin de construire.sh). */
#undef _FORTIFY_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv, char **envp) {
  char *ep;
  long addr;
  if (argc != 2) {
    fprintf(stderr, "%s: not intended to be run directly\n", argv[0]);
    return 1;
  }
  addr = strtol(argv[1], &ep, 10);
  if (*ep) {
    fprintf(stderr, "%s: invalid function address\n", argv[0]);
    return 2;
  }
  return ((int (*)(void *))addr)((void *[]){
      dlopen,
      dlsym,
      dlclose,
      dlerror,
  });
}
