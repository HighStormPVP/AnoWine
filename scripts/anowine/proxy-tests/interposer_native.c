/*
 * Native test for libano_net.dylib, run by scripts/anowine/check-proxy.sh under
 * Rosetta (x86_64) with DYLD_INSERT_LIBRARIES, ANO_PROXY_PORT and
 * ANO_WINE_DIR=/nonexistent, against ano-proxy, a real Xray SOCKS inbound and
 * the echo servers. Prints one "ok"/"FAIL" line per check; exits 1 on any FAIL.
 *
 *   interposer_native               checks 1-7 and 9-11 (helper running)
 *   interposer_native --print-dyld  exit 0 if DYLD_INSERT_LIBRARIES is set, else 3
 *   interposer_native --helper-down check 8 (ANO_PROXY_PORT points nowhere)
 *
 * This file is part of Ano, a modified version of Whisky (GPL-3.0-or-later).
 */

#include <arpa/inet.h>
#include <arpa/nameser.h>
#include <errno.h>
#include <libgen.h>
#include <limits.h>
#include <netdb.h>
#include <netinet/in.h>
#include <resolv.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;
static int failures;

static void check(const char *name, int ok)
{
    printf("%s native: %s\n", ok ? "ok  " : "FAIL", name);
    if (!ok) failures++;
}

static int echo_over(int fd)
{
    struct timeval tv = { 5, 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    if (write(fd, "PING\n", 5) != 5) return 0;
    char buf[5];
    size_t got = 0;
    while (got < 5) {
        ssize_t n = read(fd, buf + got, 5 - got);
        if (n <= 0) return 0;
        got += (size_t)n;
    }
    return memcmp(buf, "PING\n", 5) == 0;
}

static int tcp4(uint32_t addr_be, int port, int *out_fd)
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in sin = { .sin_len = sizeof(sin), .sin_family = AF_INET, .sin_port = htons(port) };
    sin.sin_addr.s_addr = addr_be;
    if (connect(fd, (struct sockaddr *)&sin, sizeof(sin)) != 0) {
        close(fd);
        return 0;
    }
    if (out_fd) {
        *out_fd = fd;
        return 1;
    }
    int ok = echo_over(fd);
    close(fd);
    return ok;
}

static uint32_t ip(const char *text)
{
    struct in_addr a;
    inet_pton(AF_INET, text, &a);
    return a.s_addr;
}

static int in_fake_range(uint32_t addr_be)
{
    uint32_t a = ntohl(addr_be);
    return (a & 0xFFFE0000u) == 0xC6120000u;
}

static int resolve(const char *name, uint32_t *out)
{
    struct addrinfo hints = { .ai_family = AF_INET, .ai_socktype = SOCK_STREAM }, *res = NULL;
    if (getaddrinfo(name, "7000", &hints, &res) != 0 || !res) return 0;
    int count = 0;
    for (struct addrinfo *ai = res; ai; ai = ai->ai_next) count++;
    *out = ((struct sockaddr_in *)res->ai_addr)->sin_addr.s_addr;
    freeaddrinfo(res);
    return count == 1;
}

static int spawn_true(void)
{
    pid_t pid;
    char *argv[] = { "/usr/bin/true", NULL };
    if (posix_spawn(&pid, "/usr/bin/true", NULL, NULL, argv, environ) != 0) return 0;
    int status = 0;
    if (waitpid(pid, &status, 0) != pid) return 0;
    return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

static void helper_running(void)
{
    uint32_t fake = 0;
    int ok = resolve("anotest.example.com", &fake);
    check("1 getaddrinfo gives one placeholder in 198.18.0.0/15", ok && in_fake_range(fake));

    int fd = -1;
    /* Only a real placeholder counts: 0.0.0.0 would reach the local echo server. */
    ok = in_fake_range(fake) && tcp4(fake, 7000, &fd) && echo_over(fd);
    struct sockaddr_in peer;
    socklen_t len = sizeof(peer);
    int peer_ok = ok && getpeername(fd, (struct sockaddr *)&peer, &len) == 0 && peer.sin_family == AF_INET &&
                  peer.sin_addr.s_addr == fake && ntohs(peer.sin_port) == 7000;
    if (fd >= 0) close(fd);
    check("2 TCP by hostname echoes through the proxy", ok);
    check("2 getpeername reports the placeholder, not the helper", peer_ok);

    check("3 TCP to 192.0.2.1:7000 echoes through the proxy", tcp4(ip("192.0.2.1"), 7000, NULL));

    int s6 = socket(AF_INET6, SOCK_STREAM, 0);
    int v6only = 1;
    setsockopt(s6, IPPROTO_IPV6, IPV6_V6ONLY, &v6only, sizeof(v6only));
    struct sockaddr_in6 sin6 = { .sin6_len = sizeof(sin6), .sin6_family = AF_INET6, .sin6_port = htons(7000) };
    inet_pton(AF_INET6, "::ffff:192.0.2.1", &sin6.sin6_addr);
    ok = connect(s6, (struct sockaddr *)&sin6, sizeof(sin6)) == 0 && echo_over(s6);
    close(s6);
    check("4 IPv6-only socket to ::ffff:192.0.2.1 is proxied", ok);

    int u = socket(AF_INET, SOCK_DGRAM, 0);
    struct sockaddr_in to = { .sin_len = sizeof(to), .sin_family = AF_INET, .sin_port = htons(7001) };
    to.sin_addr.s_addr = ip("192.0.2.1");
    errno = 0;
    ok = sendto(u, "U1", 2, 0, (struct sockaddr *)&to, sizeof(to)) == -1 && errno == EACCES;
    check("5 UDP sendto 192.0.2.1 is refused (EACCES)", ok);
    struct sockaddr_in to2 = to;
    to2.sin_addr.s_addr = ip("192.0.2.2");
    to2.sin_port = htons(7002);
    errno = 0;
    ok = connect(u, (struct sockaddr *)&to2, sizeof(to2)) == -1 && errno == EACCES;
    check("5 UDP connect to 192.0.2.2 is refused (EACCES)", ok);
    close(u);
    u = socket(AF_INET, SOCK_DGRAM, 0);
    struct timeval tv = { 3, 0 };
    setsockopt(u, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    to.sin_addr.s_addr = ip("127.0.0.1");
    char buf[4];
    ok = sendto(u, "U1", 2, 0, (struct sockaddr *)&to, sizeof(to)) == 2 && recv(u, buf, sizeof(buf), 0) == 2;
    close(u);
    check("5 UDP to 127.0.0.1 still works", ok);

    check("6 TCP to 127.0.0.1:7000 goes direct and works", tcp4(ip("127.0.0.1"), 7000, NULL));

    check("7 posix_spawn /usr/bin/true works", spawn_true());
    check("7 system(/usr/bin/true) works", system("/usr/bin/true") == 0);

    /* Wine asks for the canonical name (computer and DNS domain names). */
    struct addrinfo hints = { .ai_family = AF_INET, .ai_flags = AI_CANONNAME }, *res = NULL;
    ok = getaddrinfo("anotest.example.com", NULL, &hints, &res) == 0 && res && res->ai_canonname &&
         strcmp(res->ai_canonname, "anotest.example.com") == 0;
    if (res) freeaddrinfo(res);
    check("9 AI_CANONNAME gives the name asked for", ok);

    /* The Mac's own name is local: never a placeholder. */
    char self[256] = "";
    uint32_t own = 0;
    ok = gethostname(self, sizeof(self)) == 0 && self[0] && (!resolve(self, &own) || !in_fake_range(own));
    check("9 own hostname is not given a placeholder", ok);
    struct hostent *entry = gethostbyname(self);
    ok = !entry || entry->h_length != 4 || !entry->h_addr_list[0] || !in_fake_range(*(uint32_t *)entry->h_addr_list[0]);
    check("9 gethostbyname(own hostname) is not a placeholder", ok);

    /* Lookups that bypass getaddrinfo. Their names would show in the packet
     * capture ("anotest", "2.0.192.in-addr"), which is the real check. */
    struct in_addr probe;
    inet_pton(AF_INET, "192.0.2.9", &probe);
    check("10 gethostbyaddr(192.0.2.9) is refused", gethostbyaddr(&probe, sizeof(probe), AF_INET) == NULL);
    unsigned char answer[512];
    check("10 res_query is refused",
          res_query("anotest-query.example.com", ns_c_in, ns_t_a, answer, sizeof(answer)) < 0);
    check("10 res_search is refused",
          res_search("anotest-search.example.com", ns_c_in, ns_t_a, answer, sizeof(answer)) < 0);
}

/* Runs this program again with --print-dyld; returns its exit status, or -1. */
static int spawn_self(const char *path, int by_name)
{
    pid_t pid;
    char *argv[] = { (char *)path, "--print-dyld", NULL };
    int rc = by_name ? posix_spawnp(&pid, path, NULL, NULL, argv, environ)
                     : posix_spawn(&pid, path, NULL, NULL, argv, environ);
    if (rc != 0) return -1;
    int status = 0;
    if (waitpid(pid, &status, 0) != pid || !WIFEXITED(status)) return -1;
    return WEXITSTATUS(status);
}

/* Wine re-executes itself by resolved path and starts tools by bare name; both
 * must keep the interposer when they are inside the Wine folder, whichever way
 * that folder's path is written. */
static void wine_folder(const char *self)
{
    char real[PATH_MAX], copy[PATH_MAX], link[PATH_MAX], path[PATH_MAX * 2];
    if (!realpath(self, real)) {
        check("11 own path resolves", 0);
        return;
    }
    strlcpy(copy, real, sizeof(copy));
    const char *dir = dirname(copy);
    const char *tmp = getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp";
    snprintf(link, sizeof(link), "%s/ano-wine-link-%d", tmp, (int)getpid());
    unlink(link);
    if (symlink(dir, link) != 0) {
        check("11 symlink to the Wine folder", 0);
        return;
    }

    setenv("ANO_WINE_DIR", link, 1);
    check("11 resolved path under a symlinked Wine folder keeps the interposer", spawn_self(real, 0) == 0);
    snprintf(path, sizeof(path), "%s:%s", dir, getenv("PATH") ? getenv("PATH") : "/usr/bin:/bin");
    setenv("PATH", path, 1);
    check("11 bare name found in the Wine folder keeps the interposer", spawn_self(basename(real), 1) == 0);
    setenv("ANO_WINE_DIR", "/nonexistent", 1);
    check("11 program outside the Wine folder loses the interposer", spawn_self(real, 0) == 3);
    unlink(link);
}

static void helper_down(void)
{
    uint32_t fake = 0;
    check("8 helper down: getaddrinfo fails", !resolve("anotest.example.com", &fake));
    check("8 helper down: TCP to 192.0.2.1 fails", !tcp4(ip("192.0.2.1"), 7000, NULL));
    check("8 helper down: TCP to 127.0.0.1 still works", tcp4(ip("127.0.0.1"), 7000, NULL));
}

int main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc > 1 && strcmp(argv[1], "--print-dyld") == 0)
        return getenv("DYLD_INSERT_LIBRARIES") ? 0 : 3;
    if (argc > 1 && strcmp(argv[1], "--helper-down") == 0) {
        helper_down();
    } else {
        helper_running();
        wine_folder(argv[0]);
    }
    return failures ? 1 : 0;
}
