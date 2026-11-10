# AnoNet: `libano_net.dylib`

The network interceptor for a proxied bottle. It is an x86_64 dylib that Ano
loads with `DYLD_INSERT_LIBRARIES` into `ano-loader` and `ano-server` only
(see `ProxyEnvironment.swift`). It hooks libc calls through `__DATA,__interpose`
and sends the bottle's traffic to the per-bottle helper (`ProxyListener.swift`),
which tunnels it through the owner's proxy client (SOCKS5 or HTTP CONNECT).

Every hook passes straight through when `ANO_PROXY_PORT` is not set.

| Hook | When proxied |
|---|---|
| `getaddrinfo`, `gethostbyname`, `gethostbyname2` | Numeric hosts, `localhost`, `*.localhost`, the Mac's own hostname and `*.local` (Bonjour) names go to the real call. Any other name is sent to the helper (`R` frame), which answers with a placeholder in `198.18.0.0/15`. If the helper fails, the lookup fails. The system resolver is never asked. |
| `getnameinfo` | Always numeric, so placeholders are never looked up. |
| `gethostbyaddr`, `res_query` / `res_search` / `res_send` (and the `res_n…` forms), `DNSServiceQueryRecord`, `DNSServiceGetAddrInfo` | Refused (loopback and local names excepted): these bypass `getaddrinfo` and would ask the Mac's DNS server. Windows `DnsQuery` and reverse lookups therefore fail in a proxied bottle. |
| `connect` | TCP to a non-loopback address goes to the helper on `127.0.0.1` / `::1`, followed by a `C` frame with the real destination. UDP to a non-loopback address fails with `EACCES`. |
| `sendto`, `sendmsg` | UDP to a non-loopback address fails with `EACCES`. |
| `getpeername` | For a tunnelled socket, returns the original destination (`P` frame). |
| `execve`, `posix_spawn`, `posix_spawnp` | Programs outside `$ANO_WINE_DIR/` (compared by resolved path; bare names are looked up on `PATH`) start without `DYLD_INSERT_LIBRARIES`, because native arm64 tools abort with it. |

Environment: `ANO_PROXY_PORT` (helper port; `0` means it failed, so all network
access fails), `ANO_NET_LIB`, `ANO_WINE_DIR`, `ANO_REAL_LOADER`.

The wire protocol (`ANO1` magic, then `C` / `R` / `P` frames) is in the Global
Constraints of `docs/superpowers/plans/2026-11-10-ano-plan2a-proxy-tcp-dns.md`.

Build (x86_64, the runtime runs under Rosetta):

```sh
clang -arch x86_64 -dynamiclib -O2 -Wall -Werror -mmacosx-version-min=10.15 \
  -o libano_net.dylib AnoNet/ano_net.c -lresolv
```

Tested by `.github/workflows/AnoProxy.yml` with `scripts/anowine/check-proxy.sh`
and `scripts/anowine/proxy-tests/interposer_native.c`, against a real Xray.
