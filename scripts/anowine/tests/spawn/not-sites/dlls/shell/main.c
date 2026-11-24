/* Fixture for test_spawn_sites.py: none of these is a spawn call.
 * A comment that says execv( or system( is not code. */
#include <stdlib.h>

/* execv( */
// popen( "ls", "r" );

static const char *names[] = { "system(", "execl(\"/bin/sh\")", NULL };
static const char quote = '"';

static int run( const char *path, char **argv )
{
    if (quote == 'x') return names[0][0];
    return _execv( path, argv ) + my_system( path ) + posix_spawn_file_actions_init( NULL );
}
