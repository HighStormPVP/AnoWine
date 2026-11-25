/* An ordinary program, not marked as a builtin (runtime 5.0.1): it must not
 * find ntdll's old names, however it asks. GetProcAddress and
 * RtlFindExportedRoutineByName return nothing for each of them, and no name in
 * ntdll's export table contains "wine" in any case. Only a module carrying the
 * old mark (Apple's D3DMetal, aliastest.dll here) gets them, through the
 * loader's rewrite of its own memory. */
#include <stdio.h>
#include <ctype.h>
#include <windows.h>

static const char * const old_names[] =
{
    "__wine_unix_call_dispatcher",
    "__wine_unix_call",
    "__wine_dbg_get_channel_flags",
    "__wine_dbg_header",
    "__wine_dbg_output",
    "__wine_dbg_strdup",
};

static int has_wine( const char *name )
{
    size_t i;

    for (i = 0; name[i] && name[i + 1] && name[i + 2] && name[i + 3]; i++)
        if (tolower((unsigned char)name[i]) == 'w' && tolower((unsigned char)name[i + 1]) == 'i' &&
            tolower((unsigned char)name[i + 2]) == 'n' && tolower((unsigned char)name[i + 3]) == 'e')
            return 1;
    return 0;
}

int main(void)
{
    void *(WINAPI *find_exported)(HMODULE, const char *);
    const IMAGE_EXPORT_DIRECTORY *exports;
    const IMAGE_NT_HEADERS *nt;
    const DWORD *names;
    HMODULE ntdll = GetModuleHandleA("ntdll.dll");
    const char *base = (const char *)ntdll;
    unsigned int i, fails = 0;

    find_exported = (void *)GetProcAddress(ntdll, "RtlFindExportedRoutineByName");
    if (!find_exported)
    {
        printf("PROBE FAIL: no RtlFindExportedRoutineByName in ntdll\n");
        return 1;
    }
    for (i = 0; i < sizeof(old_names) / sizeof(old_names[0]); i++)
    {
        if (GetProcAddress(ntdll, old_names[i]))
        {
            printf("PROBE FAIL: GetProcAddress finds %s\n", old_names[i]);
            fails++;
        }
        if (find_exported(ntdll, old_names[i]))
        {
            printf("PROBE FAIL: RtlFindExportedRoutineByName finds %s\n", old_names[i]);
            fails++;
        }
    }
    nt = (const IMAGE_NT_HEADERS *)(base + ((const IMAGE_DOS_HEADER *)base)->e_lfanew);
    exports = (const IMAGE_EXPORT_DIRECTORY *)(base +
              nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXPORT].VirtualAddress);
    names = (const DWORD *)(base + exports->AddressOfNames);
    for (i = 0; i < exports->NumberOfNames; i++)
    {
        if (!has_wine(base + names[i])) continue;
        printf("PROBE FAIL: ntdll exports %s\n", base + names[i]);
        fails++;
    }
    printf("PROBE: %u ntdll export names read\n", (unsigned int)exports->NumberOfNames);
    if (fails) return 1;
    printf("PROBE: ntdll hides the old names\n");
    return 0;
}
