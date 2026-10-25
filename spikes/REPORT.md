# AnoWine feasibility spikes — report

Date: 2026-10-25
Evidence: Actions run [40176049438](https://github.com/HighStormPVP/AnoWine/actions/runs/40176049438) (`AnoWine Spikes`, `macos-15`, Apple Silicon runner, Rosetta 2), artifact `spike-logs`.
Runtime under test: frankea `v3.1.1` `Libraries.tar.gz` (Wine 11.0, Gcenx build), SHA-256 verified.

| Check | Result | Consequence |
|---|---|---|
| 1. Injection into prebuilt Wine | **GO** | The interposer approach in the spec works. |
| 2. Renamed programs | **GO** | `anowine` / `anowine-server` work, including Winetricks. |
| 3. Sandbox kill switch | **GO on CI** | Network locked to one localhost port, interposer still loaded. Metal/GPU and Steam's web helper are **not yet checked** — needs the M2 Air (Task 12). |
| 4. UDP with no real UDP packets | **GO** | Substituting Unix datagram sockets works across Wine's processes. |

## 1. Injection — GO

- `wine` and `wineserver` are **ad-hoc signed with no hardened runtime and no library validation** (`flags=0x2(adhoc)`), so `DYLD_INSERT_LIBRARIES` is honoured.
- An x86_64 dylib loaded into the loader (`wine64`→`wine`), `wineserver`, and every Windows process (`netprobe.exe`, `wineboot.exe`, `winedevice.exe`…), and saw TCP connect, DNS and UDP calls. All three `netprobe` modes passed with it loaded.
- **Inject per launch, never shell-wide.** In run 1 the variable was exported in the probe shell; it also reached arm64 helpers (`sleep`, `grep`), which aborted with "incompatible architecture (have 'x86_64', need 'arm64e')". Launching through the shim (check 3) avoided that. **For Plan 2:** Wine also spawns native macOS helpers (e.g. `open`, `/bin/sh`) that would inherit the variable, so either build the interposer for both x86_64 and arm64e, or have it remove `DYLD_INSERT_LIBRARIES` from the environment before `exec`ing anything that isn't Wine. Decide in Plan 2; test with a Windows program that opens a URL.

### Which process makes which call

| Call | Process |
|---|---|
| `socket()` (TCP and UDP) | `wineserver` |
| `connect()` (TCP) | `wineserver` |
| `bind()` (UDP, implicit `0.0.0.0:0`) | `wineserver` |
| `getaddrinfo()` | the Windows program's own process (e.g. `netprobe.exe`) |
| `sendmsg()` / `recvmsg()` (TCP and UDP data) | the Windows program's own process |
| Many `AF_INET`/`SOCK_DGRAM` sockets with no traffic | `winedevice.exe` (likely network-interface queries) |

This confirms the spec's guess (§6.2): DNS and connects happen in **different processes**, so the fake-DNS table must live in the helper, and the interposer must be loaded in `wineserver` as well as in game processes. Wine uses `sendmsg`/`recvmsg`, not `sendto`/`recvfrom`.

## 2. Renamed programs — GO

Recipe (used by Task 11):
- `Wine/bin/wine64` is a **symlink to `wine`**. Rename the real file `wine` → `anowine` and remove `wine64`.
- `Wine/bin/wineserver` is a real file → rename to `anowine-server`.
- Set `WINESERVER=<abs>/Wine/bin/anowine-server` for every launch.
- `msidb, msiexec, notepad, regedit, regsvr32, wineboot, winecfg, wineconsole, winedbg, winefile, winemine, winepath` are also symlinks to `wine`. After the rename **they dangle** (the probe listed them). They aren't used by the app (it runs `wine64 <tool>`), so Task 11 removes them rather than leaving broken links.

Verified: `anowine wineboot -i` creates a prefix; while running, `ps` shows `anowine-server` and nothing named `wineserver` or `wine64`; TCP works; `winetricks list-installed` works with `WINE=<abs>/anowine` and `anowine` on `PATH`.

## 3. Sandbox kill switch — GO on CI (hardware check pending)

Profile `spikes/sandbox/net-lockdown.sb`, launched as `sandbox-exec -D ALLOW_PORT=7001 -f net-lockdown.sb shim wine64 …`:
- Wine boots and runs inside the sandbox; `wineserver` started inside inherits it.
- Allowed `127.0.0.1:7001`: works. Other local port `7004`: blocked. Internet `1.1.1.1:443`: blocked. UDP: blocked (`WSAEACCES`).
- The interposer survives the SIP-protected `sandbox-exec` via the shim, in both loader and `wineserver`.
- **DNS leak found and closed:** macOS resolves names through `mDNSResponder` over a Unix socket, which "allow all Unix sockets" would let through. The profile now denies `/private/var/run/mDNSResponder` and the `com.apple.dnssd.service` lookup; DNS from inside the sandbox fails, as it should.
- Controls without the sandbox: same connect and DNS succeed.

Still open: does the sandbox affect Metal rendering or Steam's web helper? GitHub's runners can't show that. Task 12 gives the owner a check to run on the M2 Air.

## 4. UDP substitution — GO

`spikes/interposer/udpshim.c` + `spikes/udp_relay.py`, inside the Task 4 sandbox (UDP denied):
- `wineserver` creates the UDP socket; the shim hands back a Unix datagram socket bound under `/tmp/anowine-udp/` and connected to the relay. The game process later uses that same fd for `sendmsg`/`recvmsg`. Recognising substituted fds **by bound path** worked across processes.
- One socket, two destinations (`127.0.0.1:7002`, `127.0.0.2:7003`): both replies arrived with the **true source addresses**. The relay carried both datagrams each way. No real UDP left the sandboxed processes (the sandbox forbids it).
- Calls Wine made on substituted fds: `setsockopt(IPPROTO_IP, 28)` (ignored), `bind` (ignored), `sendmsg` (no control data), `recvmsg` requesting 512 bytes of ancillary data (we returned none — fine for this probe).

For Plan 2:
- `winedevice.exe`'s interface-query sockets were substituted too. Nothing broke here, but substituting them may hide network interfaces from Windows programs. Plan 2 should test interface listing (e.g. `GetAdaptersAddresses`) or substitute lazily, on first send.
- Connected UDP (`connect()` then `send()` without an address) wasn't implemented in the probe; Plan 2 must remember the connected destination per socket, shared across processes.
- macOS caps Unix datagrams at 2 KiB unless the socket buffers are raised. The probe raised them to 64 KiB; keep that.
- The probe's relay plays the role of Plan 2's `anowine-proxyd`, which will speak XUDP (VLESS) or SOCKS5 UDP instead of sending real UDP.

## Harness notes

- Run 1 (40175603353): the injection probe "failed" only because of the exported-variable problem above; fixed by injecting through the shim (run 2).
- First push: the Spikes workflow failed to start because `runner.temp` isn't allowed in job-level `env`. Fixed.
