/*
 * libano_net.dylib — Ano's network interceptor for a proxied bottle's Wine
 * processes. Loaded with DYLD_INSERT_LIBRARIES into ano-loader / ano-server
 * (x86_64, under Rosetta). See AnoNet/README.md and the wire protocol in
 * docs/superpowers/plans/2026-11-10-ano-plan2a-proxy-tcp-dns.md.
 *
 * Every hook passes straight through unless ANO_PROXY_PORT is set. When it is:
 *  - DNS is answered by the helper with placeholder addresses; the system
 *    resolver is never asked for a non-numeric name (fail closed).
 *  - TCP connects to anything but loopback go to the helper, which tunnels them
 *    through the owner's proxy client.
 *  - UDP to anything but loopback is refused with EACCES.
 *  - Programs outside the runtime's Wine folder are started without
 *    DYLD_INSERT_LIBRARIES (native arm64e tools abort with it).
 *
 * This file is part of Ano, a modified version of Whisky, and is licensed under
 * the GNU General Public License v3 or later.
 */

#include <arpa/inet.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <spawn.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

#define DYLD_INTERPOSE(replacement, replacee) \
    __attribute__((used)) static struct { const void *r; const void *e; } interpose_##replacee \
    __attribute__((section("__DATA,__interpose"))) = { (const void *)(unsigned long)&replacement, \
                                                       (const void *)(unsigned long)&replacee };

/* -1: not proxied (pass through). 0: proxied, helper unknown (fail closed). */
static int proxy_port(void)
{
    const char *value = getenv("ANO_PROXY_PORT");
    if (!value || !*value) return -1;
    long port = strtol(value, NULL, 10);
    return (port > 0 && port < 65536) ? (int)port : 0;
}

/* ---- addresses ------------------------------------------------------------ */

typedef struct {
    int v6;               /* 0: IPv4 in a[0..3]; 1: IPv6 in a[0..15] */
    unsigned char a[16];
    uint16_t port;        /* host order */
} dest_t;

static int dest_from_sockaddr(const struct sockaddr *sa, dest_t *d)
{
    memset(d, 0, sizeof(*d));
    if (sa->sa_family == AF_INET) {
        const struct sockaddr_in *in = (const struct sockaddr_in *)sa;
        memcpy(d->a, &in->sin_addr, 4);
        d->port = ntohs(in->sin_port);
        return 0;
    }
    if (sa->sa_family == AF_INET6) {
        const struct sockaddr_in6 *in6 = (const struct sockaddr_in6 *)sa;
        if (IN6_IS_ADDR_V4MAPPED(&in6->sin6_addr)) {
            memcpy(d->a, &in6->sin6_addr.s6_addr[12], 4);
        } else {
            d->v6 = 1;
            memcpy(d->a, &in6->sin6_addr, 16);
        }
        d->port = ntohs(in6->sin6_port);
        return 0;
    }
    return -1;
}

static int dest_is_loopback(const dest_t *d)
{
    if (!d->v6) return d->a[0] == 127;
    static const unsigned char one[16] = { [15] = 1 };
    return memcmp(d->a, one, 16) == 0;
}

static int socket_type(int fd)
{
    int type = 0;
    socklen_t len = sizeof(type);
    if (getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &len) != 0) return -1;
    return type;
}

/* ---- helper connection ---------------------------------------------------- */

static int write_all(int fd, const void *buf, size_t len)
{
    const char *p = buf;
    while (len) {
        ssize_t n = write(fd, p, len);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        p += n;
        len -= (size_t)n;
    }
    return 0;
}

static int read_all(int fd, void *buf, size_t len)
{
    char *p = buf;
    while (len) {
        ssize_t n = read(fd, p, len);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        p += n;
        len -= (size_t)n;
    }
    return 0;
}

/* Fills the helper's address for a socket of `family`: 127.0.0.1 or ::1. */
static socklen_t helper_address(int family, int port, struct sockaddr_storage *ss)
{
    memset(ss, 0, sizeof(*ss));
    if (family == AF_INET6) {
        struct sockaddr_in6 *in6 = (struct sockaddr_in6 *)ss;
        in6->sin6_len = sizeof(*in6);
        in6->sin6_family = AF_INET6;
        in6->sin6_addr = in6addr_loopback;
        in6->sin6_port = htons((uint16_t)port);
        return sizeof(*in6);
    }
    struct sockaddr_in *in = (struct sockaddr_in *)ss;
    in->sin_len = sizeof(*in);
    in->sin_family = AF_INET;
    in->sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    in->sin_port = htons((uint16_t)port);
    return sizeof(*in);
}

/* A new blocking connection to the helper, or -1. */
static int helper_open(int port)
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    struct sockaddr_storage ss;
    socklen_t len = helper_address(AF_INET, port, &ss);
    if (connect(fd, (struct sockaddr *)&ss, len) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

/* One request/reply exchange on a fresh helper connection. */
static int helper_ask(int port, const unsigned char *req, size_t req_len, unsigned char *reply, size_t reply_len)
{
    int fd = helper_open(port);
    if (fd < 0) return -1;
    int ok = write_all(fd, req, req_len) == 0 && read_all(fd, reply, reply_len) == 0;
    close(fd);
    return ok ? 0 : -1;
}

/* Placeholder IPv4 (network order) for `name`, or 0. */
static uint32_t helper_resolve(int port, const char *name)
{
    size_t len = strlen(name);
    if (port <= 0 || len == 0 || len > 253) return 0;
    unsigned char req[4 + 1 + 1 + 253];
    memcpy(req, "ANO1R", 5);
    req[5] = (unsigned char)len;
    memcpy(req + 6, name, len);
    unsigned char reply[4];
    if (helper_ask(port, req, 6 + len, reply, 4) != 0) return 0;
    uint32_t addr;
    memcpy(&addr, reply, 4);
    return addr;
}

/* ---- DNS ------------------------------------------------------------------ */

static int is_numeric_host(const char *node)
{
    unsigned char buf[16];
    return inet_pton(AF_INET, node, buf) == 1 || inet_pton(AF_INET6, node, buf) == 1;
}

static int is_localhost(const char *node)
{
    size_t len = strlen(node);
    if (len && node[len - 1] == '.') len--;
    if (len == 9 && strncasecmp(node, "localhost", 9) == 0) return 1;
    return len > 10 && strncasecmp(node + len - 10, ".localhost", 10) == 0;
}

static int ano_getaddrinfo(const char *node, const char *service, const struct addrinfo *hints,
                           struct addrinfo **res)
{
    int port = proxy_port();
    if (port < 0 || !node || is_numeric_host(node) || is_localhost(node) ||
        (hints && (hints->ai_flags & AI_NUMERICHOST)))
        return getaddrinfo(node, service, hints, res);
    if (hints && hints->ai_family == AF_INET6) return EAI_NONAME;

    uint32_t addr = helper_resolve(port, node);
    if (!addr) return EAI_FAIL;
    char text[INET_ADDRSTRLEN];
    inet_ntop(AF_INET, &addr, text, sizeof(text));

    struct addrinfo numeric;
    memset(&numeric, 0, sizeof(numeric));
    if (hints) numeric = *hints;
    numeric.ai_family = AF_INET;
    numeric.ai_flags = (numeric.ai_flags | AI_NUMERICHOST) & ~(AI_CANONNAME | AI_V4MAPPED | AI_ALL | AI_ADDRCONFIG);
    numeric.ai_addr = NULL;
    numeric.ai_canonname = NULL;
    numeric.ai_next = NULL;
    return getaddrinfo(text, service, &numeric, res);
}
DYLD_INTERPOSE(ano_getaddrinfo, getaddrinfo)

static struct hostent *fake_hostent(int port, const char *name, int af)
{
    static struct hostent entry;
    static struct in_addr address;
    static char *addresses[2];
    static char *aliases[1];
    static char stored[256];

    if (af != AF_INET) {
        h_errno = HOST_NOT_FOUND;
        return NULL;
    }
    uint32_t addr = helper_resolve(port, name);
    if (!addr) {
        h_errno = HOST_NOT_FOUND;
        return NULL;
    }
    strlcpy(stored, name, sizeof(stored));
    address.s_addr = addr;
    addresses[0] = (char *)&address;
    addresses[1] = NULL;
    aliases[0] = NULL;
    entry.h_name = stored;
    entry.h_aliases = aliases;
    entry.h_addrtype = AF_INET;
    entry.h_length = 4;
    entry.h_addr_list = addresses;
    return &entry;
}

static struct hostent *ano_gethostbyname(const char *name)
{
    int port = proxy_port();
    if (port < 0 || !name || is_numeric_host(name) || is_localhost(name)) return gethostbyname(name);
    return fake_hostent(port, name, AF_INET);
}
DYLD_INTERPOSE(ano_gethostbyname, gethostbyname)

static struct hostent *ano_gethostbyname2(const char *name, int af)
{
    int port = proxy_port();
    if (port < 0 || !name || is_numeric_host(name) || is_localhost(name)) return gethostbyname2(name, af);
    return fake_hostent(port, name, af);
}
DYLD_INTERPOSE(ano_gethostbyname2, gethostbyname2)

/* Reverse lookups would ask DNS directly; answer numerically instead. */
static int ano_getnameinfo(const struct sockaddr *sa, socklen_t salen, char *host, socklen_t hostlen,
                           char *serv, socklen_t servlen, int flags)
{
    if (proxy_port() >= 0 && host && hostlen) {
        if (flags & NI_NAMEREQD) return EAI_NONAME;
        flags |= NI_NUMERICHOST;
    }
    return getnameinfo(sa, salen, host, hostlen, serv, servlen, flags);
}
DYLD_INTERPOSE(ano_getnameinfo, getnameinfo)

/* ---- TCP and UDP ---------------------------------------------------------- */

static int ano_connect(int fd, const struct sockaddr *addr, socklen_t len)
{
    int port = proxy_port();
    dest_t d;
    if (port < 0 || !addr || dest_from_sockaddr(addr, &d) != 0 || dest_is_loopback(&d))
        return connect(fd, addr, len);

    int type = socket_type(fd);
    if (type != SOCK_STREAM) {
        errno = EACCES;
        return -1;
    }
    if (port == 0) {
        errno = ECONNREFUSED;
        return -1;
    }

    struct sockaddr_storage helper;
    socklen_t helper_len = helper_address(addr->sa_family, port, &helper);
    int flags = fcntl(fd, F_GETFL);
    if (flags >= 0 && (flags & O_NONBLOCK)) fcntl(fd, F_SETFL, flags & ~O_NONBLOCK);

    int result = connect(fd, (struct sockaddr *)&helper, helper_len);
    if (result == 0) {
        unsigned char frame[5 + 1 + 16 + 2];
        size_t n = 0;
        memcpy(frame, "ANO1C", 5);
        n = 5;
        frame[n++] = d.v6 ? 4 : 1;
        memcpy(frame + n, d.a, d.v6 ? 16 : 4);
        n += d.v6 ? 16 : 4;
        frame[n++] = (unsigned char)(d.port >> 8);
        frame[n++] = (unsigned char)(d.port & 0xFF);
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
        if (write_all(fd, frame, n) != 0) result = -1;
    }

    if (flags >= 0 && (flags & O_NONBLOCK)) fcntl(fd, F_SETFL, flags);
    if (result != 0) {
        errno = ECONNREFUSED;
        return -1;
    }
    return 0;
}
DYLD_INTERPOSE(ano_connect, connect)

static int udp_refused(int fd, const struct sockaddr *to)
{
    dest_t d;
    if (proxy_port() < 0 || !to || dest_from_sockaddr(to, &d) != 0 || dest_is_loopback(&d)) return 0;
    return socket_type(fd) == SOCK_DGRAM;
}

static ssize_t ano_sendto(int fd, const void *buf, size_t len, int flags, const struct sockaddr *to, socklen_t tolen)
{
    if (udp_refused(fd, to)) {
        errno = EACCES;
        return -1;
    }
    return sendto(fd, buf, len, flags, to, tolen);
}
DYLD_INTERPOSE(ano_sendto, sendto)

static ssize_t ano_sendmsg(int fd, const struct msghdr *msg, int flags)
{
    if (msg && msg->msg_name && udp_refused(fd, (const struct sockaddr *)msg->msg_name)) {
        errno = EACCES;
        return -1;
    }
    return sendmsg(fd, msg, flags);
}
DYLD_INTERPOSE(ano_sendmsg, sendmsg)

/* A proxied socket's real peer is the helper; report the original destination. */
static int ano_getpeername(int fd, struct sockaddr *addr, socklen_t *len)
{
    int result = getpeername(fd, addr, len);
    int port = proxy_port();
    if (result != 0 || port <= 0 || !addr || !len) return result;

    struct sockaddr_storage peer;
    socklen_t peer_len = sizeof(peer);
    dest_t d;
    if (getpeername(fd, (struct sockaddr *)&peer, &peer_len) != 0 ||
        dest_from_sockaddr((struct sockaddr *)&peer, &d) != 0 || !dest_is_loopback(&d) || d.port != port)
        return result;

    struct sockaddr_storage local;
    socklen_t local_len = sizeof(local);
    dest_t me;
    if (getsockname(fd, (struct sockaddr *)&local, &local_len) != 0 ||
        dest_from_sockaddr((struct sockaddr *)&local, &me) != 0)
        return result;

    unsigned char req[7] = { 'A', 'N', 'O', '1', 'P', (unsigned char)(me.port >> 8), (unsigned char)(me.port & 0xFF) };
    unsigned char reply[1 + 16 + 2];
    int fdh = helper_open(port);
    if (fdh < 0) return result;
    int ok = write_all(fdh, req, sizeof(req)) == 0 && read_all(fdh, reply, 1) == 0 &&
             (reply[0] == 1 || reply[0] == 4) && read_all(fdh, reply + 1, reply[0] == 1 ? 6 : 18) == 0;
    close(fdh);
    if (!ok) return result;

    struct sockaddr_storage out;
    memset(&out, 0, sizeof(out));
    socklen_t out_len;
    size_t alen = reply[0] == 1 ? 4 : 16;
    uint16_t dport = (uint16_t)(reply[1 + alen] << 8 | reply[2 + alen]);
    if (peer.ss_family == AF_INET6) {
        struct sockaddr_in6 *in6 = (struct sockaddr_in6 *)&out;
        in6->sin6_len = sizeof(*in6);
        in6->sin6_family = AF_INET6;
        in6->sin6_port = htons(dport);
        if (alen == 4) {
            in6->sin6_addr.s6_addr[10] = 0xFF;
            in6->sin6_addr.s6_addr[11] = 0xFF;
            memcpy(&in6->sin6_addr.s6_addr[12], reply + 1, 4);
        } else {
            memcpy(&in6->sin6_addr, reply + 1, 16);
        }
        out_len = sizeof(*in6);
    } else if (alen == 4) {
        struct sockaddr_in *in = (struct sockaddr_in *)&out;
        in->sin_len = sizeof(*in);
        in->sin_family = AF_INET;
        in->sin_port = htons(dport);
        memcpy(&in->sin_addr, reply + 1, 4);
        out_len = sizeof(*in);
    } else {
        return result;
    }
    memcpy(addr, &out, *len < out_len ? *len : out_len);
    *len = out_len;
    return 0;
}
DYLD_INTERPOSE(ano_getpeername, getpeername)

/* ---- starting programs ---------------------------------------------------- */

static int inside_wine(const char *path)
{
    const char *dir = getenv("ANO_WINE_DIR");
    if (!path || !dir || !*dir) return 0;
    size_t len = strlen(dir);
    return strncmp(path, dir, len) == 0 && path[len] == '/';
}

/* envp without DYLD_INSERT_LIBRARIES, or envp itself when `path` is Wine's.
 * The returned array (if new) is leaked: callers exec or spawn right away. */
static char *const *environment_for(const char *path, char *const envp[])
{
    if (!envp || inside_wine(path)) return envp;
    size_t count = 0;
    while (envp[count]) count++;
    char **filtered = calloc(count + 1, sizeof(char *));
    if (!filtered) return envp;
    size_t n = 0;
    for (size_t i = 0; i < count; i++)
        if (strncmp(envp[i], "DYLD_INSERT_LIBRARIES=", 22) != 0) filtered[n++] = envp[i];
    filtered[n] = NULL;
    return filtered;
}

static int ano_execve(const char *path, char *const argv[], char *const envp[])
{
    return execve(path, argv, environment_for(path, envp));
}
DYLD_INTERPOSE(ano_execve, execve)

static int ano_posix_spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *actions,
                           const posix_spawnattr_t *attr, char *const argv[], char *const envp[])
{
    return posix_spawn(pid, path, actions, attr, argv, environment_for(path, envp));
}
DYLD_INTERPOSE(ano_posix_spawn, posix_spawn)

static int ano_posix_spawnp(pid_t *pid, const char *file, const posix_spawn_file_actions_t *actions,
                            const posix_spawnattr_t *attr, char *const argv[], char *const envp[])
{
    return posix_spawnp(pid, file, actions, attr, argv, environment_for(file, envp));
}
DYLD_INTERPOSE(ano_posix_spawnp, posix_spawnp)
