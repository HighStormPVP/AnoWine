/*
 * shim: re-arms DYLD_INSERT_LIBRARIES inside the sandbox. Throwaway.
 *
 * sandbox-exec is SIP-protected, so macOS strips DYLD_* variables when it
 * starts. We pass the library path in ANOWINE_INSERT instead; this shim (not
 * protected) copies it back into DYLD_INSERT_LIBRARIES and execs the program.
 *
 * Usage: shim <program> [args...]
 * Build: clang -arch arm64 -arch x86_64 -O2 -o shim shim.c
 */
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    const char *insert = getenv("ANOWINE_INSERT");

    if (argc < 2) {
        fprintf(stderr, "usage: shim <program> [args...]\n");
        return 2;
    }
    if (insert && *insert)
        setenv("DYLD_INSERT_LIBRARIES", insert, 1);
    unsetenv("ANOWINE_INSERT");
    execv(argv[1], argv + 1);
    perror("shim: execv");
    return 127;
}
