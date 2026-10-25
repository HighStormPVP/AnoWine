/*
 * udpshim: AnoWine spike go/no-go #3. Throwaway.
 *
 * Replaces every IP datagram socket a Wine process creates with an AF_UNIX
 * datagram socket connected to a relay (path in ANOWINE_UDP_RELAY), so the
 * sandboxed processes never emit a real UDP packet. Each datagram carries a
 * 19-byte header: [u8 family (4|6)][u16 port, big endian][16-byte address].
 *
 * Substituted fds are recognised by their bound path prefix, never by an
 * in-process table: Wine creates sockets in one process (wineserver) and
 * passes the fds to another (the game process).
 *
 * Logs to ANOWINE_SPIKE_LOG like logshim, plus "subcall" lines for every
 * other call seen on a substituted fd.
 *
 * Build: clang -arch x86_64 -dynamiclib -O2 -o libudpshim.dylib udpshim.c
 */
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <sys/un.h>
#include <unistd.h>

#define DYLD_INTERPOSE(_replacement, _replacee)                                   \
    __attribute__((used)) static struct {                                         \
        const void *replacement;                                                  \
        const void *replacee;                                                     \
    } _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = {   \
        (const void *)(unsigned long)&_replacement,                               \
        (const void *)(unsigned long)&_replacee};

#define SUB_DIR "/tmp/anowine-udp"
#define HDR_LEN 19
#define MAX_DGRAM 65536

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
    fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0644);
    if (fd < 0)
        return;
    write(fd, buf, (size_t)n);
    close(fd);
}

/* Is fd one of our substituted sockets? Checked via its bound path. */
static int is_sub(int fd)
{
    struct sockaddr_un sun;
    socklen_t len = sizeof(sun);

    memset(&sun, 0, sizeof(sun));
    if (getsockname(fd, (struct sockaddr *)&sun, &len) != 0 || sun.sun_family != AF_UNIX)
        return 0;
    return strncmp(sun.sun_path, SUB_DIR "/", sizeof(SUB_DIR)) == 0 ||
           strncmp(sun.sun_path, "/private" SUB_DIR "/", sizeof("/private" SUB_DIR)) == 0;
}

/* Stable fake local port derived from the bound path. */
static uint16_t fake_port(int fd)
{
    struct sockaddr_un sun;
    socklen_t len = sizeof(sun);
    uint32_t h = 2166136261u;
    const char *p;

    memset(&sun, 0, sizeof(sun));
    getsockname(fd, (struct sockaddr *)&sun, &len);
    for (p = sun.sun_path; *p; p++)
        h = (h ^ (uint8_t)*p) * 16777619u;
    return (uint16_t)(40000 + h % 20000);
}

static int encode_hdr(const struct sockaddr *sa, uint8_t *hdr)
{
    memset(hdr, 0, HDR_LEN);
    if (!sa)
        return -1;
    if (sa->sa_family == AF_INET) {
        const struct sockaddr_in *sin = (const struct sockaddr_in *)sa;
        hdr[0] = 4;
        memcpy(hdr + 1, &sin->sin_port, 2);
        memcpy(hdr + 3, &sin->sin_addr, 4);
        return 0;
    }
    if (sa->sa_family == AF_INET6) {
        const struct sockaddr_in6 *sin6 = (const struct sockaddr_in6 *)sa;
        hdr[0] = 6;
        memcpy(hdr + 1, &sin6->sin6_port, 2);
        memcpy(hdr + 3, &sin6->sin6_addr, 16);
        return 0;
    }
    return -1;
}

static void decode_hdr(const uint8_t *hdr, struct sockaddr *out, socklen_t *outlen)
{
    struct sockaddr_storage ss;
    socklen_t len;

    memset(&ss, 0, sizeof(ss));
    if (hdr[0] == 6) {
        struct sockaddr_in6 *sin6 = (struct sockaddr_in6 *)&ss;
        sin6->sin6_len = sizeof(*sin6);
        sin6->sin6_family = AF_INET6;
        memcpy(&sin6->sin6_port, hdr + 1, 2);
        memcpy(&sin6->sin6_addr, hdr + 3, 16);
        len = sizeof(*sin6);
    } else {
        struct sockaddr_in *sin = (struct sockaddr_in *)&ss;
        sin->sin_len = sizeof(*sin);
        sin->sin_family = AF_INET;
        memcpy(&sin->sin_port, hdr + 1, 2);
        memcpy(&sin->sin_addr, hdr + 3, 4);
        len = sizeof(*sin);
    }
    if (out && outlen) {
        memcpy(out, &ss, *outlen < len ? *outlen : len);
        *outlen = len;
    }
}

static int my_socket(int domain, int type, int protocol)
{
    static int counter;
    const char *relay = getenv("ANOWINE_UDP_RELAY");
    int base_type = type & 0xffff;
    struct sockaddr_un me, peer;
    int fd, size = MAX_DGRAM + HDR_LEN;

    if (!relay || (domain != AF_INET && domain != AF_INET6) || base_type != SOCK_DGRAM)
        return socket(domain, type, protocol);

    fd = socket(AF_UNIX, SOCK_DGRAM, 0);
    if (fd < 0)
        return fd;
    mkdir(SUB_DIR, 0700);
    memset(&me, 0, sizeof(me));
    me.sun_family = AF_UNIX;
    snprintf(me.sun_path, sizeof(me.sun_path), SUB_DIR "/%d-%d", (int)getpid(), ++counter);
    unlink(me.sun_path);
    memset(&peer, 0, sizeof(peer));
    peer.sun_family = AF_UNIX;
    snprintf(peer.sun_path, sizeof(peer.sun_path), "%s", relay);
    /* macOS caps Unix datagrams at net.local.dgram.maxdgram (2 KiB) unless raised. */
    setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, sizeof(size));
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, sizeof(size));
    if (bind(fd, (struct sockaddr *)&me, sizeof(me)) != 0 ||
        connect(fd, (struct sockaddr *)&peer, sizeof(peer)) != 0) {
        int err = errno;
        logline("socket-sub FAILED errno=%d path=%s", err, me.sun_path);
        close(fd);
        errno = err;
        return -1;
    }
    logline("socket-sub %d/%d fd=%d path=%s", domain, base_type, fd, me.sun_path);
    return fd;
}
DYLD_INTERPOSE(my_socket, socket)

static ssize_t send_wrapped(int fd, const struct sockaddr *dest, const struct iovec *iov, int iovcnt)
{
    uint8_t hdr[HDR_LEN];
    struct iovec v[17];
    struct msghdr m;
    ssize_t r;
    int i;

    if (encode_hdr(dest, hdr) != 0) {
        logline("subcall send-without-destination fd=%d", fd);
        errno = EDESTADDRREQ;
        return -1;
    }
    if (iovcnt > 16) {
        errno = EMSGSIZE;
        return -1;
    }
    v[0].iov_base = hdr;
    v[0].iov_len = HDR_LEN;
    for (i = 0; i < iovcnt; i++)
        v[i + 1] = iov[i];
    memset(&m, 0, sizeof(m));
    m.msg_iov = v;
    m.msg_iovlen = iovcnt + 1;
    r = sendmsg(fd, &m, 0);
    return r >= HDR_LEN ? r - HDR_LEN : r;
}

static ssize_t my_sendto(int fd, const void *buf, size_t n, int flags,
                         const struct sockaddr *addr, socklen_t len)
{
    struct iovec v;
    if (!is_sub(fd))
        return sendto(fd, buf, n, flags, addr, len);
    v.iov_base = (void *)buf;
    v.iov_len = n;
    logline("subcall sendto fd=%d flags=%d", fd, flags);
    return send_wrapped(fd, addr, &v, 1);
}
DYLD_INTERPOSE(my_sendto, sendto)

static ssize_t my_sendmsg(int fd, const struct msghdr *msg, int flags)
{
    if (!is_sub(fd))
        return sendmsg(fd, msg, flags);
    logline("subcall sendmsg fd=%d flags=%d controllen=%u", fd, flags, (unsigned)msg->msg_controllen);
    return send_wrapped(fd, (const struct sockaddr *)msg->msg_name, msg->msg_iov, (int)msg->msg_iovlen);
}
DYLD_INTERPOSE(my_sendmsg, sendmsg)

static ssize_t recv_wrapped(int fd, struct iovec *iov, int iovcnt, int flags,
                            struct sockaddr *from, socklen_t *fromlen)
{
    uint8_t hdr[HDR_LEN];
    struct iovec v[17];
    struct msghdr m;
    ssize_t r;
    int i;

    if (iovcnt > 16) {
        errno = EMSGSIZE;
        return -1;
    }
    v[0].iov_base = hdr;
    v[0].iov_len = HDR_LEN;
    for (i = 0; i < iovcnt; i++)
        v[i + 1] = iov[i];
    memset(&m, 0, sizeof(m));
    m.msg_iov = v;
    m.msg_iovlen = iovcnt + 1;
    r = recvmsg(fd, &m, flags);
    if (r < 0)
        return r;
    if (r < HDR_LEN) {
        errno = EIO;
        return -1;
    }
    decode_hdr(hdr, from, fromlen);
    return r - HDR_LEN;
}

static ssize_t my_recvfrom(int fd, void *buf, size_t n, int flags,
                           struct sockaddr *addr, socklen_t *len)
{
    struct iovec v;
    if (!is_sub(fd))
        return recvfrom(fd, buf, n, flags, addr, len);
    v.iov_base = buf;
    v.iov_len = n;
    logline("subcall recvfrom fd=%d flags=%d", fd, flags);
    return recv_wrapped(fd, &v, 1, flags, addr, len);
}
DYLD_INTERPOSE(my_recvfrom, recvfrom)

static ssize_t my_recvmsg(int fd, struct msghdr *msg, int flags)
{
    ssize_t r;
    socklen_t namelen;
    if (!is_sub(fd))
        return recvmsg(fd, msg, flags);
    logline("subcall recvmsg fd=%d flags=%d controllen=%u", fd, flags, (unsigned)msg->msg_controllen);
    namelen = msg->msg_namelen;
    r = recv_wrapped(fd, msg->msg_iov, (int)msg->msg_iovlen, flags,
                     (struct sockaddr *)msg->msg_name, msg->msg_name ? &namelen : NULL);
    if (r >= 0) {
        msg->msg_namelen = msg->msg_name ? namelen : 0;
        msg->msg_controllen = 0;
        msg->msg_flags = 0;
    }
    return r;
}
DYLD_INTERPOSE(my_recvmsg, recvmsg)

static int my_getsockname(int fd, struct sockaddr *addr, socklen_t *len)
{
    struct sockaddr_in sin;
    if (!is_sub(fd) || !addr || !len)
        return getsockname(fd, addr, len);
    memset(&sin, 0, sizeof(sin));
    sin.sin_len = sizeof(sin);
    sin.sin_family = AF_INET;
    sin.sin_port = htons(fake_port(fd));
    memcpy(addr, &sin, *len < sizeof(sin) ? *len : sizeof(sin));
    *len = sizeof(sin);
    return 0;
}
DYLD_INTERPOSE(my_getsockname, getsockname)

static int my_bind(int fd, const struct sockaddr *addr, socklen_t len)
{
    if (is_sub(fd) && addr && addr->sa_family != AF_UNIX) {
        logline("subcall bind fd=%d (ignored)", fd);
        return 0;
    }
    return bind(fd, addr, len);
}
DYLD_INTERPOSE(my_bind, bind)

static int my_connect(int fd, const struct sockaddr *addr, socklen_t len)
{
    if (is_sub(fd) && addr && addr->sa_family != AF_UNIX) {
        logline("subcall connect fd=%d (not implemented in spike)", fd);
        return 0;
    }
    return connect(fd, addr, len);
}
DYLD_INTERPOSE(my_connect, connect)

static int my_getpeername(int fd, struct sockaddr *addr, socklen_t *len)
{
    if (is_sub(fd)) {
        logline("subcall getpeername fd=%d", fd);
        errno = ENOTCONN;
        return -1;
    }
    return getpeername(fd, addr, len);
}
DYLD_INTERPOSE(my_getpeername, getpeername)

static int my_setsockopt(int fd, int level, int name, const void *val, socklen_t len)
{
    if (is_sub(fd) && (level == IPPROTO_IP || level == IPPROTO_IPV6 ||
                       (level == SOL_SOCKET && name == SO_BROADCAST))) {
        logline("subcall setsockopt fd=%d level=%d name=%d (ignored)", fd, level, name);
        return 0;
    }
    return setsockopt(fd, level, name, val, len);
}
DYLD_INTERPOSE(my_setsockopt, setsockopt)

static int my_getsockopt(int fd, int level, int name, void *val, socklen_t *len)
{
    if (is_sub(fd) && (level == IPPROTO_IP || level == IPPROTO_IPV6 ||
                       (level == SOL_SOCKET && name == SO_BROADCAST))) {
        logline("subcall getsockopt fd=%d level=%d name=%d (zeroed)", fd, level, name);
        if (val && len)
            memset(val, 0, *len);
        return 0;
    }
    return getsockopt(fd, level, name, val, len);
}
DYLD_INTERPOSE(my_getsockopt, getsockopt)

__attribute__((constructor)) static void loaded(void)
{
    logline("loaded udpshim relay=%s", getenv("ANOWINE_UDP_RELAY") ? getenv("ANOWINE_UDP_RELAY") : "-");
}
