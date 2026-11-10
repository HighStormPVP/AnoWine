/* Test program for check-ano-programs.sh: calls user32's ExitWindowsEx, which
 * starts the boot program (ano-boot.exe) to end the session, then stays alive
 * long enough for the check to see that program running. Not shipped. */
#include <windows.h>
#include <stdio.h>

int main(void)
{
    BOOL ok = ExitWindowsEx(EWX_LOGOFF, SHTDN_REASON_MAJOR_OTHER);
    printf("ExitWindowsEx=%d\n", ok ? 1 : 0);
    fflush(stdout);
    Sleep(3000);
    return ok ? 0 : 1;
}
