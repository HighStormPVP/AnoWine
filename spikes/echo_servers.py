"""Echo servers for the AnoWine spikes. Throwaway.

TCP echo on 127.0.0.1:7001 and 127.0.0.1:7004.
UDP echo on 127.0.0.1:7002 and 127.0.0.2:7003 (needs `ifconfig lo0 alias 127.0.0.2`).
Runs until killed.
"""
import socket
import sys
import threading


def tcp_echo(host, port):
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((host, port))
    srv.listen(16)
    while True:
        conn, _ = srv.accept()
        threading.Thread(target=_serve_tcp, args=(conn,), daemon=True).start()


def _serve_tcp(conn):
    with conn:
        while True:
            data = conn.recv(4096)
            if not data:
                return
            conn.sendall(data)


def udp_echo(host, port):
    srv = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    srv.bind((host, port))
    while True:
        data, peer = srv.recvfrom(4096)
        srv.sendto(data, peer)


def main():
    threads = [
        threading.Thread(target=tcp_echo, args=("127.0.0.1", 7001), daemon=True),
        threading.Thread(target=tcp_echo, args=("127.0.0.1", 7004), daemon=True),
        threading.Thread(target=udp_echo, args=("127.0.0.1", 7002), daemon=True),
        threading.Thread(target=udp_echo, args=("127.0.0.2", 7003), daemon=True),
    ]
    for t in threads:
        t.start()
    print("echo servers up", flush=True)
    for t in threads:
        t.join()


if __name__ == "__main__":
    sys.exit(main())
