/* Fixture for test_spawn_sites.py: a re-exec that runs before the process
 * sets anything, and a function name split over two lines. */
#include <unistd.h>

static const struct table entries[] =
{
    { 1, 2 },
};

#ifdef __APPLE__
static void
exec_loader( char **argv )
#else
static void exec_loader( char **argv )
#endif
{
    if (argv[1]) { execv( argv[1], argv + 1 ); }
}
