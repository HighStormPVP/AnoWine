/* A stand-in for a closed builtin DLL such as Apple's D3DMetal d3d11.dll
 * (Plan 3c-1, Task 4): marked "Wine builtin DLL" by check-aliases.sh, it
 * imports ntdll's old names and calls its Mac half through the old
 * unix-call table. It loads only if the engine keeps those aliases. */
#include <windows.h>
#include <winternl.h>

typedef UINT64 unixlib_handle_t;
__declspec(dllimport) extern NTSTATUS (WINAPI *__wine_unix_call_dispatcher)(unixlib_handle_t, unsigned int, void *);
__declspec(dllimport) const char * __cdecl __wine_dbg_strdup(const char *);
__declspec(dllimport) int __cdecl __wine_dbg_output(const char *);
/* CW HACK 22435 in ntdll/loader.c: "Needed by D3DMetal PE DLLs". */
__declspec(dllimport) NTSTATUS WINAPI __wine_unix_call(unixlib_handle_t, unsigned int, void *);
/* mingw's winternl.h does not declare it; the class is Wine's private one. */
NTSTATUS NTAPI NtQueryVirtualMemory(HANDLE, PVOID, int, PVOID, SIZE_T, SIZE_T *);
extern IMAGE_DOS_HEADER __ImageBase;

/* MemoryWineUnixFuncs: the unix-call table of a builtin module. */
#define MEMORY_UNIX_FUNCS 1000

__declspec(dllexport) int WINAPI alias_call(int value)
{
    unixlib_handle_t handle = 0;
    NTSTATUS status;
    int other = value;

    __wine_dbg_output(__wine_dbg_strdup(""));
    status = NtQueryVirtualMemory(GetCurrentProcess(), &__ImageBase, MEMORY_UNIX_FUNCS,
                                  &handle, sizeof(handle), NULL);
    if (status) return -1;
    if (__wine_unix_call_dispatcher(handle, 0, &value)) return -2;
    if (__wine_unix_call(handle, 0, &other)) return -4;
    return value == other ? value : -5;
}
