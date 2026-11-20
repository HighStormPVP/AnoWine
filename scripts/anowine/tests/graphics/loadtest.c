/* Plan 3c-2: loads each DLL named on the command line by full path and prints
 * "LOADED <path>", or "FAIL <path> (...)" when it does not load or another
 * module of the same name loads instead. For a DLL that exports
 * D3D11CreateDevice it also creates a device and prints "CREATE <path> <hr>"
 * (reported only: a CI runner promises no GPU). Exit 1 if any DLL does not
 * load. An exception ends the run with FAIL instead of starting the crash
 * debugger, whose dialog would wait for a click. */
#include <stdio.h>
#include <windows.h>

typedef HRESULT (WINAPI *create_device_fn)(void *adapter, int driver_type, HMODULE software, UINT flags,
                                           const void *levels, UINT count, UINT sdk_version, void **device,
                                           void *level, void **context);

static const char *current = "";

static LONG WINAPI on_exception(EXCEPTION_POINTERS *info)
{
    printf("FAIL %s (exception %08lx)\n", current, info->ExceptionRecord->ExceptionCode);
    fflush(stdout);
    ExitProcess(1);
    return EXCEPTION_EXECUTE_HANDLER;
}

int main(int argc, char **argv)
{
    int i, failed = 0;

    SetUnhandledExceptionFilter(on_exception);
    for (i = 1; i < argc; i++)
    {
        HMODULE module;
        create_device_fn create;

        char loaded[MAX_PATH];

        current = argv[i];
        /* Its own folder first, as when the app copies a set into a bottle. */
        module = LoadLibraryExA(argv[i], NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
        if (!module)
        {
            printf("FAIL %s (error %lu)\n", argv[i], GetLastError());
            failed = 1;
            continue;
        }
        /* Wine applies DLL load order even to a full path: the builtin of the
         * same name could stand in for the file asked for. */
        if (!GetModuleFileNameA(module, loaded, sizeof(loaded)) || lstrcmpiA(loaded, argv[i]))
        {
            printf("FAIL %s (loaded %s instead)\n", argv[i], loaded);
            failed = 1;
            continue;
        }
        printf("LOADED %s\n", argv[i]);
        create = (create_device_fn)(void *)GetProcAddress(module, "D3D11CreateDevice");
        if (create)
        {
            void *device = NULL, *context = NULL;
            /* D3D_DRIVER_TYPE_HARDWARE = 1, D3D11_SDK_VERSION = 7 */
            HRESULT hr = create(NULL, 1, NULL, 0, NULL, 0, 7, &device, NULL, &context);
            printf("CREATE %s %08lx\n", argv[i], (unsigned long)hr);
        }
        fflush(stdout);
    }
    return failed;
}
