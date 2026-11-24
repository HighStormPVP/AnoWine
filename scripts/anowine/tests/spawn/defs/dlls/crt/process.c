/* Fixture for test_spawn_sites.py: the C runtime's own system(), a
 * definition on the Windows side, and its prototype. */
#include <stdlib.h>

int CDECL system(const char* cmd);

/*********************************************************************
 *		system (CRT.@)
 */
int CDECL system(const char* cmd)
{
    return cmd ? create_process( cmd ) : 1;
}
