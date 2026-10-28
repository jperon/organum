/* Lie le programme d'aide de cosmo_dlopen aux plus anciennes versions des
   symboles de la glibc x86-64 (2.2.5) : il fonctionne alors avec toute glibc
   ultérieure, sans compilateur sur la machine cible. */
__asm__(".symver dlopen,dlopen@GLIBC_2.2.5");
__asm__(".symver dlsym,dlsym@GLIBC_2.2.5");
__asm__(".symver dlclose,dlclose@GLIBC_2.2.5");
__asm__(".symver dlerror,dlerror@GLIBC_2.2.5");
__asm__(".symver strtol,strtol@GLIBC_2.2.5");
__asm__(".symver fprintf,fprintf@GLIBC_2.2.5");
__asm__(".symver __libc_start_main,__libc_start_main@GLIBC_2.2.5");

/* Point d'entrée maison : celui de la glibc (Scrt1.o) appellerait
   __libc_start_main@GLIBC_2.34. Même code que le démarrage x86-64 standard. */
__asm__(".text\n"
        ".globl _start\n"
        "_start:\n"
        "  xor %ebp, %ebp\n"
        "  mov %rdx, %r9\n"          /* rtld_fini */
        "  pop %rsi\n"               /* argc */
        "  mov %rsp, %rdx\n"         /* argv */
        "  and $-16, %rsp\n"
        "  push %rax\n"
        "  push %rsp\n"
        "  xor %r8d, %r8d\n"         /* fini */
        "  xor %ecx, %ecx\n"         /* init */
        "  lea main(%rip), %rdi\n"
        "  call *__libc_start_main@GOTPCREL(%rip)\n"
        "  hlt\n");
