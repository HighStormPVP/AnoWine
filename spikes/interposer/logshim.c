/*
 * logshim: DYLD-interposed logger for the AnoWine feasibility spikes.
 * Throwaway. Logs socket-related libc calls made by Wine processes to the
 * file named by ANOWINE_SPIKE_LOG, then calls the real function.
 *
 * Line format: <pid> <progname> <func> <family>/<type> <addr:port|host|->
 *
 * Build: clang -arch x86_64 -dynamiclib -O2 -o liblogshim.dylib logshim.c
 */
#include <arpa/inet.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/un.h>
#include <unistd.h>

#define DYLD_INTERPOSE(_replacement, _replacee)                                   \
    __attribute__((used)) static struct {                                         \
        const void *replacement;                                                  \
        const void *replacee;                                                     \
    } _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = {   \
        (const void *)(unsigned long)&_replacement,                               \
        (const void *)(unsigned long)&_replacee};

static void logline(const char *fmt, ...)
{
    const char *path = getenv("ANOWINE_SPIKE_LOG");
    char buf[512];
    int fd, n;
    va_list ap;

    if (!path)
        return;
    n = snprintf(buf, sizeof(buf), "%d %s ", (int)getpid(), getprogname());
    va_start(ap, fmt);
    n += vsnprintf(buf + n, sizeof(buf) - (size_t)n, fmt, ap);
    va_end(ap);
    if (n >= (int)sizeof(buf) - 1)
        n = (int)sizeof(buf) - 2;
    buf[n++] = '\n';
    /* Open per write with O_APPEND so lines from several processes interleave safely. */
    fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0644);
    if (fd < 0)
        return;
    write(fd, buf, (size_t)n);
    close(fd);
}

static const char *fmt_addr(const struct sockaddr *sa, char *out, size_t len)
{
    char ip[INET6_ADDRSTRLEN];

    if (!sa)
        return "-";
    switch (sa->sa_family) {
    case AF_INET: {
        const struct sockaddr_in *sin = (const struct sockaddr_in *)sa;
        inet_ntop(AF_INET, &sin->sin_addr, ip, sizeof(ip));
        snprintf(out, len, "%s:%d", ip, ntohs(sin->sin_port));
        return out;
    }
    case AF_INET6: {
        const struct sockaddr_in6 *sin6 = (const struct sockaddr_in6 *)sa;
        inet_ntop(AF_INET6, &sin6->sin6_addr, ip, sizeof(ip));
        snprintf(out, len, "[%s]:%d", ip, ntohs(sin6->sin6_port));
        return out;
    }
    case AF_UNIX:
        snprintf(out, len, "unix:%s", ((const struct sockaddr_un *)sa)->sun_path);
        return out;
    default:
        snprintf(out, len, "family%d", sa->sa_family);
        return out;
    }
}

static void fd_kind(int fd, int *family, int *type)
{
    struct sockaddr_storage ss;
    socklen_t len = sizeof(ss), tlen = sizeof(*type);

    *family = -1;
    *type = -1;
    if (getsockname(fd, (struct sockaddr *)&ss, &len) == 0)
        *family = ss.ss_family;
    getsockopt(fd, SOL_SOCKET, SO_TYPE, type, &tlen);
}

static int my_socket(int domain, int type, int protocol)
{
    int fd = socket(domain, type, protocol);
    logline("socket %d/%d fd=%d", domain, type, fd);
    return fd;
}
DYLD_INTERPOSE(my_socket, socket)

static int my_connect(int fd, const struct sockaddr *addr, socklen_t len)
{
    char a[128];
    int fam, typ;
    fd_kind(fd, &fam, &typ);
    if (addr && addr->sa_family != AF_UNIX)
        logline("connect %d/%d %s", fam, typ, fmt_addr(addr, a, sizeof(a)));
    return connect(fd, addr, len);
}
DYLD_INTERPOSE(my_connect, connect)

static int my_bind(int fd, const struct sockaddr *addr, socklen_t len)
{
    char a[128];
    int fam, typ;
    fd_kind(fd, &fam, &typ);
    if (addr && addr->sa_family != AF_UNIX)
        logline("bind %d/%d %s", fam, typ, fmt_addr(addr, a, sizeof(a)));
    return bind(fd, addr, len);
}
DYLD_INTERPOSE(my_bind, bind)

static ssize_t my_sendto(int fd, const void *buf, size_t n, int flags,
                         const struct sockaddr *addr, socklen_t len)
{
    char a[128];
    int fam, typ;
    fd_kind(fd, &fam, &typ);
    if (fam != AF_UNIX)
        logline("sendto %d/%d %s", fam, typ, fmt_addr(addr, a, sizeof(a)));
    return sendto(fd, buf, n, flags, addr, len);
}
DYLD_INTERPOSE(my_sendto, sendto)

static ssize_t my_sendmsg(int fd, const struct msghdr *msg, int flags)
{
    char a[128];
    int fam, typ;
    fd_kind(fd, &fam, &typ);
    if (fam != AF_UNIX)
        logline("sendmsg %d/%d %s", fam, typ,
                fmt_addr(msg ? (const struct sockaddr *)msg->msg_name : NULL, a, sizeof(a)));
    return sendmsg(fd, msg, flags);
}
DYLD_INTERPOSE(my_sendmsg, sendmsg)

static ssize_t my_recvfrom(int fd, void *buf, size_t n, int flags,
                           struct sockaddr *addr, socklen_t *len)
{
    char a[128];
    int fam, typ;
    ssize_t r = recvfrom(fd, buf, n, flags, addr, len);
    fd_kind(fd, &fam, &typ);
    if (fam != AF_UNIX)
        logline("recvfrom %d/%d %s r=%zd", fam, typ, r >= 0 ? fmt_addr(addr, a, sizeof(a)) : "-", r);
    return r;
}
DYLD_INTERPOSE(my_recvfrom, recvfrom)

static ssize_t my_recvmsg(int fd, struct msghdr *msg, int flags)
{
    char a[128];
    int fam, typ;
    ssize_t r = recvmsg(fd, msg, flags);
    fd_kind(fd, &fam, &typ);
    if (fam != AF_UNIX)
        logline("recvmsg %d/%d %s r=%zd", fam, typ,
                (r >= 0 && msg) ? fmt_addr((const struct sockaddr *)msg->msg_name, a, sizeof(a)) : "-", r);
    return r;
}
DYLD_INTERPOSE(my_recvmsg, recvmsg)

static int my_getaddrinfo(const char *node, const char *service,
                          const struct addrinfo *hints, struct addrinfo **res)
{
    logline("getaddrinfo - %s", node ? node : "-");
    return getaddrinfo(node, service, hints, res);
}
DYLD_INTERPOSE(my_getaddrinfo, getaddrinfo)

__attribute__((constructor)) static void loaded(void)
{
    logline("loaded - -");
}
