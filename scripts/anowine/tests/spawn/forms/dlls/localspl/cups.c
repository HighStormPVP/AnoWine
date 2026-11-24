/* Fixture for test_spawn_sites.py: every form of spawn call the scan looks
 * for, one per function. */
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <spawn.h>
#include <crt_externs.h>

static BOOL pipe_start_doc( doc_t *doc, const char *cmdA )
{
    if ((doc->pipe.pid = fork()) == 0)
    {
        signal( SIGPIPE, SIG_DFL );
        execl( "/bin/sh", "/bin/sh", "-c", cmdA, NULL );
        _exit( 1 );
    }
    return doc->pipe.pid != -1;
}

static BOOL is_postscript_supported(void)
{
    const char *const argv[] = { "/usr/sbin/cupsfilter", "--list-filters", NULL };
    pid_t pid;

    if (posix_spawn(&pid, argv[0], NULL, NULL, argv, *_NSGetEnviron()) != 0) return FALSE;
    return TRUE;
}

static BOOL run_spawnp( char **argv )
{
    pid_t pid;

    return !posix_spawnp( &pid, argv[0], NULL, NULL, argv, *_NSGetEnviron() );
}

static int
run_system( const char *command )
{
    return system(command);
}

static FILE *run_popen( const char *command )
{
    return popen ( command, "r" );
}
