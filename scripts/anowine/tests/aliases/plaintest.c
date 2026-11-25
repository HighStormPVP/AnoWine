/* The plain stand-in (runtime 5.0.1): a builtin DLL with Ano's own mark, as
 * every module the engine builds has. check-env-aliases.sh marks it "Ano
 * builtin DLL". Its Mac half (aliastest_unix.c built with -DANO_PLAIN) reads
 * WINED3DMETAL and WINEESYNC as Apple's libd3dshared.dylib would. In a process
 * that has not loaded a module with the old mark, both must be unset: the
 * engine sets them only for a closed part's Mac library. */
#include <windows.h>
#include <winternl.h>

typedef UINT64 unixlib_handle_t;
__declspec(dllimport) NTSTATUS WINAPI __ano_unix_call(unixlib_handle_t, unsigned int, void *);
/* mingw's winternl.h does not declare it; the class is Ano's private one. */
NTSTATUS NTAPI NtQueryVirtualMemory(HANDLE, PVOID, int, PVOID, SIZE_T, SIZE_T *);
extern IMAGE_DOS_HEADER __ImageBase;

/* MemoryAnoUnixFuncs: the unix-call table of a builtin module. */
#define MEMORY_UNIX_FUNCS 1000

struct env_args { char d3dmetal[16]; char esync[16]; };

__declspec(dllexport) int WINAPI plain_env(struct env_args *env)
{
    unixlib_handle_t handle = 0;

    if (NtQueryVirtualMemory(GetCurrentProcess(), &__ImageBase, MEMORY_UNIX_FUNCS,
                             &handle, sizeof(handle), NULL)) return -1;
    return __ano_unix_call(handle, 1, env) ? -2 : 0;
}
