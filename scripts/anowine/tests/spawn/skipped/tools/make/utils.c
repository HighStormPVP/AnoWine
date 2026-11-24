/* Fixture for test_spawn_sites.py: build tools are not scanned. */
#include <stdlib.h>

int run_tool( const char *command )
{
    return system( command );
}
