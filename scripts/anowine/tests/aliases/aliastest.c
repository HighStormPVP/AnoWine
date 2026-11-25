/* A stand-in for a closed builtin DLL such as Apple's D3DMetal d3d11.dll
 * (Plan 3c-1, Task 4): marked "Wine builtin DLL" by check-aliases.sh, it
 * imports ntdll's old names and calls its Mac half through the old
 * unix-call table. It loads only if the engine keeps those aliases.
 * Runtime 5.0.1: it also looks old names up at run time, as Wine's winecrt0
 * does (RtlFindExportedRoutineByName) and as any DLL may (GetProcAddress). */
#include <windows.h>
#include <winternl.h>

typedef UINT64 unixlib_handle_t;
__declspec(dllimport) extern NTSTATUS (WINAPI *__wine_unix_call_dispatcher)(unixlib_handle_t, unsigned int, void *);
__declspec(dllimport) const char * __cdecl __wine_dbg_strdup(const char *);
__declspec(dllimport) int __cdecl __wine_dbg_output(const char *);
/* CW HACK 22435 in ntdll/loader.c: "Needed by D3DMetal PE DLLs". */
__declspec(dllimport) NTSTATUS WINAPI __wine_unix_call(unixlib_handle_t, unsigned int, void *);
__declspec(dllimport) void * WINAPI RtlFindExportedRoutineByName(HMODULE, const char *);
/* mingw's winternl.h does not declare it; the class is Wine's private one. */
NTSTATUS NTAPI NtQueryVirtualMemory(HANDLE, PVOID, int, PVOID, SIZE_T, SIZE_T *);
extern IMAGE_DOS_HEADER __ImageBase;

/* MemoryWineUnixFuncs: the unix-call table of a builtin module. */
#define MEMORY_UNIX_FUNCS 1000

__declspec(dllexport) int WINAPI alias_call(int value)
{
    unixlib_handle_t handle = 0;
    NTSTATUS status;
    HMODULE ntdll;
    int other = value;

    __wine_dbg_output(__wine_dbg_strdup(""));
    status = NtQueryVirtualMemory(GetCurrentProcess(), &__ImageBase, MEMORY_UNIX_FUNCS,
                                  &handle, sizeof(handle), NULL);
    if (status) return -1;
    if (__wine_unix_call_dispatcher(handle, 0, &value)) return -2;
    if (__wine_unix_call(handle, 0, &other)) return -4;
    if (value != other) return -5;
    ntdll = GetModuleHandleA("ntdll.dll");
    if (RtlFindExportedRoutineByName(ntdll, "__wine_unix_call_dispatcher") != (void *)&__wine_unix_call_dispatcher)
        return -6;
    if (GetProcAddress(ntdll, "__wine_dbg_output") != (FARPROC)__wine_dbg_output) return -7;
    return value;
}

/* Plan 3c-4a, Task 6: what the Mac half sees of WINED3DMETAL and WINEESYNC. */
struct env_args { char d3dmetal[16]; char esync[16]; };

__declspec(dllexport) int WINAPI alias_env(struct env_args *env)
{
    unixlib_handle_t handle = 0;

    if (NtQueryVirtualMemory(GetCurrentProcess(), &__ImageBase, MEMORY_UNIX_FUNCS,
                             &handle, sizeof(handle), NULL)) return -1;
    return __wine_unix_call(handle, 1, env) ? -2 : 0;
}
