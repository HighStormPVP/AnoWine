/*
 * netprobe: tiny Windows console program used by the AnoWine feasibility
 * spikes. Throwaway.
 *
 *   netprobe dns <host>                        print resolved IPv4s
 *   netprobe tcp <host> <port>                 send "PING\n", expect it echoed
 *   netprobe connect <ip> <port>               TCP connect only
 *   netprobe udp <ip1> <port1> <ip2> <port2>   one socket, two destinations,
 *                                              expect both echoed within 3 s
 *
 * Exit code 0 on success, 1 on failure.
 */
#include <winsock2.h>
#include <ws2tcpip.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int do_dns(const char *host)
{
    struct addrinfo hints, *res, *ai;
    char buf[INET_ADDRSTRLEN];
    int n = 0;

    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    if (getaddrinfo(host, NULL, &hints, &res) != 0) {
        printf("dns: getaddrinfo failed: %d\n", WSAGetLastError());
        return 1;
    }
    for (ai = res; ai; ai = ai->ai_next) {
        struct sockaddr_in *sin = (struct sockaddr_in *)ai->ai_addr;
        inet_ntop(AF_INET, &sin->sin_addr, buf, sizeof(buf));
        printf("%s\n", buf);
        n++;
    }
    freeaddrinfo(res);
    return n > 0 ? 0 : 1;
}

static int do_tcp(const char *host, const char *port)
{
    struct addrinfo hints, *res;
    SOCKET s;
    DWORD timeout = 5000;
    char reply[8] = {0};
    int got = 0, r;

    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host, port, &hints, &res) != 0) {
        printf("tcp: getaddrinfo failed: %d\n", WSAGetLastError());
        return 1;
    }
    s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (const char *)&timeout, sizeof(timeout));
    if (connect(s, res->ai_addr, (int)res->ai_addrlen) != 0) {
        printf("tcp: connect failed: %d\n", WSAGetLastError());
        freeaddrinfo(res);
        closesocket(s);
        return 1;
    }
    freeaddrinfo(res);
    send(s, "PING\n", 5, 0);
    while (got < 5 && (r = recv(s, reply + got, 5 - got, 0)) > 0)
        got += r;
    closesocket(s);
    if (got == 5 && memcmp(reply, "PING\n", 5) == 0) {
        printf("tcp: echo ok\n");
        return 0;
    }
    printf("tcp: bad or missing echo (%d bytes)\n", got);
    return 1;
}

static int do_connect(const char *ip, const char *port)
{
    struct sockaddr_in sin;
    SOCKET s;
    int ok;

    memset(&sin, 0, sizeof(sin));
    sin.sin_family = AF_INET;
    sin.sin_port = htons((unsigned short)atoi(port));
    if (inet_pton(AF_INET, ip, &sin.sin_addr) != 1) {
        printf("connect: bad address\n");
        return 1;
    }
    s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    ok = connect(s, (struct sockaddr *)&sin, sizeof(sin)) == 0;
    if (!ok)
        printf("connect: failed: %d\n", WSAGetLastError());
    else
        printf("connect: ok\n");
    closesocket(s);
    return ok ? 0 : 1;
}

static int fill_addr(struct sockaddr_in *sin, const char *ip, const char *port)
{
    memset(sin, 0, sizeof(*sin));
    sin->sin_family = AF_INET;
    sin->sin_port = htons((unsigned short)atoi(port));
    return inet_pton(AF_INET, ip, &sin->sin_addr) == 1 ? 0 : -1;
}

static int do_udp(const char *ip1, const char *p1, const char *ip2, const char *p2)
{
    struct sockaddr_in d1, d2, from;
    int fromlen, r, got1 = 0, got2 = 0, tries;
    SOCKET s;
    DWORD timeout = 3000;
    char buf[64], ipbuf[INET_ADDRSTRLEN];

    if (fill_addr(&d1, ip1, p1) || fill_addr(&d2, ip2, p2)) {
        printf("udp: bad address\n");
        return 1;
    }
    s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (s == INVALID_SOCKET) {
        printf("udp: socket failed: %d\n", WSAGetLastError());
        return 1;
    }
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (const char *)&timeout, sizeof(timeout));
    if (sendto(s, "U1", 2, 0, (struct sockaddr *)&d1, sizeof(d1)) != 2)
        printf("udp: sendto 1 failed: %d\n", WSAGetLastError());
    if (sendto(s, "U2", 2, 0, (struct sockaddr *)&d2, sizeof(d2)) != 2)
        printf("udp: sendto 2 failed: %d\n", WSAGetLastError());
    for (tries = 0; tries < 2 && !(got1 && got2); tries++) {
        fromlen = sizeof(from);
        r = recvfrom(s, buf, sizeof(buf) - 1, 0, (struct sockaddr *)&from, &fromlen);
        if (r <= 0) {
            printf("udp: recvfrom failed: %d\n", WSAGetLastError());
            break;
        }
        buf[r] = 0;
        inet_ntop(AF_INET, &from.sin_addr, ipbuf, sizeof(ipbuf));
        printf("from %s:%d %s\n", ipbuf, ntohs(from.sin_port), buf);
        if (strcmp(buf, "U1") == 0) got1 = 1;
        if (strcmp(buf, "U2") == 0) got2 = 1;
    }
    closesocket(s);
    return (got1 && got2) ? 0 : 1;
}

int main(int argc, char **argv)
{
    WSADATA wsa;
    int rc = 2;

    setvbuf(stdout, NULL, _IONBF, 0);
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
        printf("WSAStartup failed\n");
        return 1;
    }
    if (argc == 3 && strcmp(argv[1], "dns") == 0)
        rc = do_dns(argv[2]);
    else if (argc == 4 && strcmp(argv[1], "tcp") == 0)
        rc = do_tcp(argv[2], argv[3]);
    else if (argc == 4 && strcmp(argv[1], "connect") == 0)
        rc = do_connect(argv[2], argv[3]);
    else if (argc == 6 && strcmp(argv[1], "udp") == 0)
        rc = do_udp(argv[2], argv[3], argv[4], argv[5]);
    else
        printf("usage: netprobe dns <host> | tcp <host> <port> | udp <ip1> <p1> <ip2> <p2>\n");
    WSACleanup();
    return rc;
}
