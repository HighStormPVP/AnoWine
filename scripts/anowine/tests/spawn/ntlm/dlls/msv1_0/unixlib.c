/* Fixture for test_spawn_sites.py: msv1_0's ntlm_fork hands the live
 * environment to ntlm_auth. Another function calls the helper, which does
 * not handle the spawn in ntlm_fork. */
#include <spawn.h>

#ifdef __APPLE__
# include <crt_externs.h>
# define environ (*_NSGetEnviron())
#else
  extern char **environ;
#endif

static char **unused_copy;

static NTSTATUS ntlm_cleanup( void *args )
{
    unused_copy = ano_env_without_aliases();
    return STATUS_SUCCESS;
}

static NTSTATUS ntlm_fork( void *args )
{
    const struct fork_params *params = args;
    struct ntlm_ctx *ctx = params->ctx;
    posix_spawn_file_actions_t file_actions;
    int err;

    posix_spawn_file_actions_init( &file_actions );

    if ((err = posix_spawnp( &ctx->pid, params->argv[0], &file_actions, NULL, params->argv, environ )))
    {
        ctx->pid = -1;
        return STATUS_UNSUCCESSFUL;
    }

    posix_spawn_file_actions_destroy( &file_actions );
    return STATUS_SUCCESS;
}
