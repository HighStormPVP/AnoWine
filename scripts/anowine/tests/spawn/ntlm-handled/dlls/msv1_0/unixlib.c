/* Fixture for test_spawn_sites.py: ntlm_fork passes a copy of the
 * environment without the old names (patches/rename/0006). */
#include <spawn.h>

#ifdef __APPLE__
# include <crt_externs.h>
# define environ (*_NSGetEnviron())
#else
  extern char **environ;
#endif

static NTSTATUS ntlm_fork( void *args )
{
    const struct fork_params *params = args;
    struct ntlm_ctx *ctx = params->ctx;
    posix_spawn_file_actions_t file_actions;
    char **env = ano_env_without_aliases();
    int err;

    posix_spawn_file_actions_init( &file_actions );

    err = posix_spawnp( &ctx->pid, params->argv[0], &file_actions, NULL, params->argv, env );
    if (env != environ) free( env );
    if (err)
    {
        ctx->pid = -1;
        return STATUS_UNSUCCESSFUL;
    }

    posix_spawn_file_actions_destroy( &file_actions );
    return STATUS_SUCCESS;
}
