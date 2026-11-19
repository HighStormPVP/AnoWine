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
extern IMAGE_DOS_HEADER __ImageBase;

/* MemoryWineUnixFuncs: the unix-call table of a builtin module. */
#define MEMORY_UNIX_FUNCS 1000

__declspec(dllexport) int WINAPI alias_call(int value)
{
    unixlib_handle_t handle = 0;
    NTSTATUS status;

    __wine_dbg_output(__wine_dbg_strdup(""));
    status = NtQueryVirtualMemory(GetCurrentProcess(), &__ImageBase, MEMORY_UNIX_FUNCS,
                                  &handle, sizeof(handle), NULL);
    if (status) return -1;
    if (__wine_unix_call_dispatcher(handle, 0, &value)) return -2;
    return value;
}
