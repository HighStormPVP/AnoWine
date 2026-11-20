/* Plan 3c-2: loads each DLL named on the command line by full path and prints
 * "LOADED <path>", or "FAIL <path> (...)" when it does not load or another
 * module of the same name loads instead. Then, for each loaded DLL that
 * exports D3D11CreateDevice, it creates a device and prints
 * "CREATE <path> <hr>" (reported only: a CI runner promises no GPU). Every DLL
 * is loaded before any device is created, so a crash while creating one does
 * not hide whether the others load. Exit 1 if any DLL does not load. An
 * exception ends the run with FAIL instead of starting the crash debugger,
 * whose dialog would wait for a click. */
#include <stdio.h>
#include <windows.h>

typedef HRESULT (WINAPI *create_device_fn)(void *adapter, int driver_type, HMODULE software, UINT flags,
                                           const void *levels, UINT count, UINT sdk_version, void **device,
                                           void *level, void **context);

static const char *current = "";
static int creating;

static LONG WINAPI on_exception(EXCEPTION_POINTERS *info)
{
    printf("%s %s (exception %08lx)\n", creating ? "CRASH" : "FAIL", current,
           info->ExceptionRecord->ExceptionCode);
    fflush(stdout);
    ExitProcess(1);
    return EXCEPTION_EXECUTE_HANDLER;
}

int main(int argc, char **argv)
{
    HMODULE modules[64] = {0};
    int i, failed = 0;

    SetUnhandledExceptionFilter(on_exception);
    for (i = 1; i < argc && i < 64; i++)
    {
        char loaded[MAX_PATH];

        current = argv[i];
        /* Its own folder first, as when the app copies a set into a bottle. */
        modules[i] = LoadLibraryExA(argv[i], NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
        if (!modules[i])
        {
            printf("FAIL %s (error %lu)\n", argv[i], GetLastError());
            failed = 1;
            continue;
        }
        /* Wine applies DLL load order even to a full path: the builtin of the
         * same name could stand in for the file asked for. */
        if (!GetModuleFileNameA(modules[i], loaded, sizeof(loaded)) || lstrcmpiA(loaded, argv[i]))
        {
            printf("FAIL %s (loaded %s instead)\n", argv[i], loaded);
            modules[i] = NULL;
            failed = 1;
            continue;
        }
        printf("LOADED %s\n", argv[i]);
    }
    fflush(stdout);

    creating = 1;
    for (i = 1; i < argc && i < 64; i++)
    {
        create_device_fn create;
        void *device = NULL, *context = NULL;
        HRESULT hr;

        if (!modules[i]) continue;
        create = (create_device_fn)(void *)GetProcAddress(modules[i], "D3D11CreateDevice");
        if (!create) continue;
        current = argv[i];
        printf("CREATING %s\n", argv[i]);
        fflush(stdout);
        /* D3D_DRIVER_TYPE_HARDWARE = 1, D3D11_SDK_VERSION = 7 */
        hr = create(NULL, 1, NULL, 0, NULL, 0, 7, &device, NULL, &context);
        printf("CREATE %s %08lx\n", argv[i], (unsigned long)hr);
        fflush(stdout);
    }
    return failed;
}
