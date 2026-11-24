/* Fixture for test_spawn_sites.py: tests are not scanned. */
#include <stdio.h>

static void test_pipe(void)
{
    FILE *f = popen( "echo ok", "r" );
    pclose( f );
}
