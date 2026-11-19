/* The Mac half of aliastest.dll: it exports only the old unix-call table name. */
typedef int NTSTATUS;

static NTSTATUS twice(void *args)
{
    *(int *)args *= 2;
    return 0;
}

__attribute__((visibility("default"))) const void *__wine_unix_call_funcs[] = { (const void *)twice };
