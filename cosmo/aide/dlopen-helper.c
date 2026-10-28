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
