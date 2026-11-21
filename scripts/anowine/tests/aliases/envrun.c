/* Plan 3c-4a, Task 6: D3DMetal's two variables through the engine's hidden
 * alias. Started with ANOD3DMETAL=1 ANOESYNC=1, prints what the Mac half of
 * aliastest.dll reads (as Apple's libd3dshared.dylib would), then what the
 * Windows environment says, then runs a child that pings for a few seconds,
 * so check-env-aliases.sh can look at both processes with ps -E. */
#include <stdio.h>
#include <windows.h>

struct env_args { char d3dmetal[16]; char esync[16]; };

static LONG WINAPI on_exception(EXCEPTION_POINTERS *info)
{
    printf("FAIL: exception %08lx\n", info->ExceptionRecord->ExceptionCode);
    fflush(stdout);
    ExitProcess(1);
    return EXCEPTION_EXECUTE_HANDLER;
}

static const char *windows_value(const char *name, char *buffer, DWORD size)
{
    return GetEnvironmentVariableA(name, buffer, size) ? buffer : "-";
}

int main(void)
{
    int (WINAPI *alias_env)(struct env_args *);
    struct env_args env = { "?", "?" };
    char d3dmetal[16], esync[16], command[] = "cmd.exe /c ping -n 8 127.0.0.1";
    STARTUPINFOA startup = { sizeof(startup) };
    PROCESS_INFORMATION child;
    HMODULE module;
    int result;

    SetUnhandledExceptionFilter(on_exception);
    module = LoadLibraryA("aliastest.dll");
    if (!module)
    {
        printf("FAIL: aliastest.dll does not load (error %lu)\n", GetLastError());
        return 1;
    }
    alias_env = (void *)GetProcAddress(module, "alias_env");
    result = alias_env ? alias_env(&env) : -3;
    printf("unix: WINED3DMETAL=%s WINEESYNC=%s (call %d)\n", env.d3dmetal, env.esync, result);
    printf("windows: WINED3DMETAL=%s WINEESYNC=%s\n", windows_value("WINED3DMETAL", d3dmetal, sizeof(d3dmetal)),
           windows_value("WINEESYNC", esync, sizeof(esync)));
    fflush(stdout);
    if (!CreateProcessA(NULL, command, NULL, NULL, FALSE, 0, NULL, NULL, &startup, &child))
    {
        printf("FAIL: no child (error %lu)\n", GetLastError());
        return 1;
    }
    WaitForSingleObject(child.hProcess, 60000);
    printf("child: done\n");
    return 0;
}
