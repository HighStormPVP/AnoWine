/* Loads aliastest.dll and calls through to its Mac half. A missing import
 * does not stop the load (Wine binds it to a stub that raises an exception
 * when called), so an exception is reported here and ends the run instead of
 * starting the crash debugger, whose dialog would wait for a click. */
#include <stdio.h>
#include <windows.h>

static LONG WINAPI on_exception(EXCEPTION_POINTERS *info)
{
    printf("FAIL: exception %08lx in aliastest.dll\n", info->ExceptionRecord->ExceptionCode);
    fflush(stdout);
    ExitProcess(1);
    return EXCEPTION_EXECUTE_HANDLER;
}

int main(void)
{
    int (WINAPI *call)(int);
    HMODULE module;
    int result;

    SetUnhandledExceptionFilter(on_exception);
    module = LoadLibraryA("aliastest.dll");
    if (!module)
    {
        printf("FAIL: aliastest.dll does not load (error %lu)\n", GetLastError());
        return 1;
    }
    call = (void *)GetProcAddress(module, "alias_call");
    result = call ? call(21) : -3;
    printf("RESULT: alias_call(21) = %d\n", result);
    return result == 42 ? 0 : 1;
}
