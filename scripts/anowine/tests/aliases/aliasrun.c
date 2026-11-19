/* Loads aliastest.dll and calls through to its Mac half. */
#include <stdio.h>
#include <windows.h>

int main(void)
{
    int (WINAPI *call)(int);
    HMODULE module = LoadLibraryA("aliastest.dll");
    int result;

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
