"""UDP relay for the AnoWine UDP spike. Throwaway. Runs OUTSIDE the sandbox.

Listens on a Unix datagram socket. Each datagram from a substituted Wine
socket carries a 19-byte header: [u8 family 4|6][u16 port BE][16-byte addr].
For every client path the relay keeps one real UDP socket (so the source port
is stable across destinations), sends the payload to the destination, and
returns replies to the client path with the true source in the header.

Usage: python3 udp_relay.py <relay-socket-path> <log-file>
"""
import os
import select
import socket
import struct
import sys

HDR = 19


def encode(addr):
    host, port = addr[0], addr[1]
    if ":" in host:
        return bytes([6]) + struct.pack(">H", port) + socket.inet_pton(socket.AF_INET6, host)
    return bytes([4]) + struct.pack(">H", port) + socket.inet_pton(socket.AF_INET, host) + bytes(12)


def decode(hdr):
    port = struct.unpack(">H", hdr[1:3])[0]
    if hdr[0] == 6:
        return socket.AF_INET6, (socket.inet_ntop(socket.AF_INET6, hdr[3:19]), port)
    return socket.AF_INET, (socket.inet_ntop(socket.AF_INET, hdr[3:7]), port)


def main():
    path, log_path = sys.argv[1], sys.argv[2]
    log = open(log_path, "a", buffering=1)
    if os.path.exists(path):
        os.unlink(path)
    relay = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    relay.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 1 << 17)
    relay.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 17)
    relay.bind(path)
    clients = {}   # client unix path -> {family: udp socket}
    owners = {}    # udp socket -> client unix path
    log.write("relay up %s\n" % path)
    while True:
        ready, _, _ = select.select([relay] + list(owners), [], [])
        for s in ready:
            if s is relay:
                data, client = relay.recvfrom(1 << 17)
                if len(data) < HDR:
                    continue
                family, dest = decode(data[:HDR])
                per = clients.setdefault(client, {})
                if family not in per:
                    u = socket.socket(family, socket.SOCK_DGRAM)
                    per[family] = u
                    owners[u] = client
                per[family].sendto(data[HDR:], dest)
                log.write("out %s -> %s:%d %d bytes\n" % (client, dest[0], dest[1], len(data) - HDR))
            else:
                payload, src = s.recvfrom(1 << 16)
                relay.sendto(encode(src) + payload, owners[s])
                log.write("in %s:%d -> %s %d bytes\n" % (src[0], src[1], owners[s], len(payload)))


if __name__ == "__main__":
    sys.exit(main())
