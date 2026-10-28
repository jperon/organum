// Inclus avant tout fichier du moteur (-include) : JUCE se compile en mode
// Linux, et cosmopolitan reçoit les quelques déclarations qui lui manquent.
#define __linux__ 1
#ifdef __cplusplus
#include <dirent.h>
#include <sys/stat.h>
#include <dlfcn.h>
#include <pthread.h>
#include <net/if.h>
#include <langinfo.h>
#ifndef PTHREAD_PRIO_INHERIT
#define PTHREAD_PRIO_INHERIT 1
static inline int pthread_mutexattr_setprotocol(pthread_mutexattr_t*, int) { return 0; }
#endif
#ifndef _NL_ADDRESS_LANG_AB
#define _NL_ADDRESS_LANG_AB CODESET
#define _NL_ADDRESS_COUNTRY_AB2 CODESET
#endif
#ifndef ifr_hwaddr
#define ifr_hwaddr ifr_addr
#endif
static inline int mkfifo(const char *p, mode_t m) { return mknod(p, S_IFIFO | m, 0); }
#endif
