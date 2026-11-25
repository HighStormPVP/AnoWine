/* The Mac half of aliastest.dll: it exports only the old unix-call table name.
 * env_values reads the environment from inside the process, as Apple's
 * libd3dshared.dylib does (Plan 3c-4a, Task 6: D3DMetal reads WINED3DMETAL
 * and WINEESYNC itself). */
#include <stdlib.h>
#include <string.h>

typedef int NTSTATUS;

struct env_args { char d3dmetal[16]; char esync[16]; };

static NTSTATUS twice(void *args)
{
    *(int *)args *= 2;
    return 0;
}

static void copy_env(char *out, const char *name)
{
    const char *value = getenv(name);

    strncpy(out, value ? value : "-", 15);
    out[15] = 0;
}

static NTSTATUS env_values(void *args)
{
    struct env_args *env = args;

    copy_env(env->d3dmetal, "WINED3DMETAL");
    copy_env(env->esync, "WINEESYNC");
    return 0;
}

/* -DANO_PLAIN builds the Mac half of plaintest.dll (runtime 5.0.1), which has
 * Ano's own table name, as every module the engine builds does. */
#ifdef ANO_PLAIN
#define UNIX_CALL_FUNCS __ano_unix_call_funcs
#else
#define UNIX_CALL_FUNCS __wine_unix_call_funcs
#endif

__attribute__((visibility("default"))) const void *UNIX_CALL_FUNCS[] = {
    (const void *)twice,
    (const void *)env_values,
};
