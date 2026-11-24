/* Fixture for test_spawn_sites.py: Objective-C files are scanned too. */
#include <stdlib.h>

static int open_with_shell( const char *command )
{
    return system( command );
}

@implementation MacApp

    - (void) openFile:(NSString *)path withApp:(NSString *)app
    {
        execlp( "open", "open", [path UTF8String], NULL );
    }

@end
