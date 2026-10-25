# AnoWine — Design

Date: 2026-10-25
Status: draft, awaiting owner approval

## 1. What this is, and why

AnoWine is a macOS app for playing Windows games on Apple Silicon Macs, in the spirit of CrossOver.
Steam is the centre of it: the owner wants to install the Windows Steam client into a bottle and play
"any game really" from their library.

It is built on **frankea/Whisky** (https://github.com/frankea/Whisky), the actively maintained GPL-3
community fork of the archived Whisky app. That fork already does the hard work of a game launcher:
Wine 11.0 (Gcenx build) under Rosetta 2, D3DMetal / DXMT / DXVK graphics backends, launcher support
(Steam, Epic, Battle.net…), 80+ per-game configurations, diagnostics, tests and CI.

What makes AnoWine its own app is a **built-in, per-bottle proxy with DNS-leak protection and a
kill switch**. The owner wants it "as a cool feature" — it is an extra, not the reason games run.
The owner is happy to put a lot of work into this over time.

### Why not the alternatives (decided)

- **Not the original Whisky-App/Whisky:** archived April 2025, based on CrossOver 22.1.1, and its
  Wine runtime download URL (`data.getwhisky.app`) returns 404.
- **Not a from-scratch app:** months of duplicated work.
- **Not a PR to frankea's fork:** owner chose to have their own app.

## 2. Goals

1. A rebranded app, **AnoWine**, built from frankea/Whisky, installable side-by-side with Whisky.
2. Everything frankea's fork does for games keeps working, and keeps improving as we pull upstream.
3. A per-bottle **Proxy** setting: when on, all of that bottle's TCP **and UDP** traffic and DNS
   lookups go through the user's **existing local Xray client** (owner uses Xray, VLESS + XTLS to
   their server). Two upstream modes:
   - **Local VLESS (primary, strict TCP):** the owner adds a VLESS inbound on `127.0.0.1` to their
     Xray client; AnoWine carries TCP and UDP to it inside TCP. No UDP packets exist anywhere on the
     machine.
   - **SOCKS5 (fallback, no Xray config needed):** TCP via CONNECT, UDP via standard UDP ASSOCIATE
     (a UDP hop on loopback only). HTTP CONNECT proxies also accepted for TCP-only use.
4. **No DNS leaks** while the proxy is on: hostnames are resolved by the proxy, never locally.
5. **Kill switch:** while the proxy is on, if the proxy path is down, the bottle has no network.
   It must never silently fall back to the direct connection.
6. Built and tested on free GitHub Actions macOS runners (public repo).

## 3. Non-goals

- The QEMU/HVF Windows 11 ARM VM from the original sketch — no GPU acceleration, useless for games.
- Any server-side component (UDP relay, udpgw). UDP rides the owner's existing Xray tunnel (§6.5).
- Bundling `xray-core` / importing `vless://` links into AnoWine — possible later upgrade, not v1.
- TUN-based tun2socks, Dokodemo-door or TProxy routing: need root/system-wide capture, or (on macOS)
  lose each packet's original destination. Considered and rejected.
- Filesystem sandboxing of bottles. Only *network* is restricted.
- Building or patching Wine. We consume the same prebuilt runtime as upstream.
- Anti-cheat support (EAC/BattlEye/Vanguard) — not achievable under Wine on macOS.
- Intel Macs.
- Notarization in v1 (no paid Apple Developer account). Can be added later.

## 4. Anti-goals (failure even if it "works")

- **Proxy-off must be zero-impact.** A bottle with the proxy off must launch exactly as upstream
  would: no injected library, no sandbox, no helper. Games must not get slower or break because the
  feature exists.
- **No false sense of protection.** If any traffic class is *not* covered (UDP, ICMP, anything we
  can't intercept), the UI says so. A leak while the UI claims protection is the worst outcome.
- **No fork drift that makes upstream merges painful.** Prefer new files over edits to upstream files;
  keep internal module/type names (`WhiskyKit`, `Bottle`, etc.) unchanged.
- No telemetry beyond what upstream already has (off by default) — and none of it may go around the
  proxy for a proxied bottle.

## 5. Constraints

- **Dev machine is Windows.** All compiling, unit tests and automated Wine tests run on GitHub Actions
  `macos-15` (Apple Silicon) runners. The owner has an **M2 MacBook Air** (fanless; RAM unknown) for
  real game testing; it is the only place rendering/performance can be verified.
- **Public GitHub repo**, created as a GitHub fork of frankea/Whisky so upstream merges stay simple.
- **License: GPL-3**, inherited. Keep LICENSE, upstream credits, and note that it is modified.
- **D3DMetal (Apple GPTK) cannot be redistributed.** Keep upstream's behaviour: the user supplies
  GPTK; the app imports it.
- **Rosetta 2 timeline:** fully available through macOS 27 (current). From macOS 28 (~late 2027) Apple
  limits it to certain older games. Not solved here, but nothing in this design should make a later
  move to an arm64 Wine harder (see §9).
- **No Apple Developer account:** builds are ad-hoc signed. First launch on macOS 15+ requires
  System Settings → Privacy & Security → "Open Anyway" (the old right-click → Open bypass was removed
  in Sequoia). README must explain this.

## 6. The proxy feature (decided design)

### 6.1 Shape

```
 game.exe / steam.exe (x86_64 Wine, under Rosetta)        AnoWine app (arm64)
 ┌──────────────────────────────────────────┐            ┌───────────────────────┐
 │ wine64 / wineserver processes            │            │ anowine-proxyd        │
 │  + libanowine_net.dylib (interposer)     │──TCP──────▶│ (helper, per bottle,  │──▶ owner's Xray
 │    connect / getaddrinfo / sendto …      │ 127.0.0.1  │  random localhost port)│    client: local
 └──────────────────────────────────────────┘   :PORT    └───────────────────────┘    VLESS inbound
                                                                                      (or SOCKS5) ──▶
                                                                                      VLESS+XTLS to server
        ▲ launched inside sandbox-exec profile: outbound network only to 127.0.0.1:PORT
```

Three parts:

1. **`libanowine_net.dylib`** — a small C interposer library (proxychains-style) loaded into the
   bottle's Wine processes via `DYLD_INSERT_LIBRARIES`. Must be built for **x86_64** (Wine runs
   under Rosetta); build it universal so an arm64 Wine later is easy.
2. **`anowine-proxyd`** — a helper process started by the app for each running proxied bottle. It
   speaks to the owner's Xray client — **VLESS** (primary) or SOCKS5 / HTTP CONNECT (fallback) —
   holds credentials, and owns the fake-DNS table. Written in Swift to match the codebase (builder's
   choice of networking API). All protocol work lives here; the interposer stays thin and only
   forwards intercepted calls to the helper over one local TCP connection (or a few).
3. **A `sandbox-exec` profile** applied when launching a proxied bottle, allowing outbound network
   only to the helper's localhost port (plus the local Unix sockets Wine needs — see §6.6). This is
   the kill switch and the leak backstop: even traffic the interposer misses cannot leave.

### 6.2 DNS (no leaks)

The interposer replaces `getaddrinfo` / `gethostbyname` (and anything else Wine's unix side uses for
resolution). Instead of resolving, it asks the helper for a **fake IPv4 address** from a reserved
range (e.g. 198.18.0.0/15) mapped to that hostname. When a socket later connects to a fake IP, the
helper sends the *hostname* upstream (VLESS domain address type / SOCKS5 `ATYP=domain` /
`CONNECT host:port`), so Xray resolves it on the server side. The mapping
lives in the helper, not the library, because in current Wine the DNS lookup and the actual
`connect()` may happen in different processes (game process vs. `wineserver`) — **verify this early**.

IPv6: return no AAAA results while proxied, and route/deny IPv6 connects so nothing goes direct.

### 6.3 TCP

The interposer redirects `connect()` on TCP sockets to `127.0.0.1:PORT` and tells the helper the real
destination (small framing header, builder's choice). Wine uses **non-blocking connects**, and
`wineserver` is single-threaded, so the interposer must **not block** waiting for the upstream proxy:
connect to the helper (local, instant), hand over the destination, and let the helper report failure
by closing the connection. `getpeername()` must return the original destination, not localhost.
Connections to loopback/LAN addresses: builder decides, but default to *also* proxying or blocking —
never sending direct while the UI says "protected"; local Unix sockets are unaffected.

### 6.4 Credentials and settings

- Proxy profiles are stored app-wide. Types:
  - **VLESS (local Xray inbound):** host (default `127.0.0.1`), port, UUID, transport **raw TCP**
    (default) or **WebSocket** (path). No TLS (loopback only). No gRPC (needs a full HTTP/2 stack for
    no benefit on loopback).
  - **SOCKS5:** host, port (default `127.0.0.1:10808`), optional username/password.
  - **HTTP CONNECT:** host, port, optional credentials; TCP only, so UDP is blocked in this mode.
- Secrets (VLESS UUID, passwords) live in the **macOS Keychain**, never in bottle settings files or
  environment variables.
- README/help shows a ready-to-paste Xray inbound snippet for the local VLESS mode, listening on
  `127.0.0.1` only.
- Each bottle has: Proxy **off** (default) / **on with profile X**.
- The helper gets credentials from the app (not via the game's environment).
- Settings live in a new settings struct alongside upstream's `BottleSettings` (new file), decoded with
  defaults so upstream bottles open unchanged.

### 6.5 UDP and everything else

- **UDP is tunnelled, not blocked** (owner's decision). The interposer intercepts UDP socket
  operations (`sendto`/`sendmsg`/`recvfrom`/`recvmsg`/`connect`/`bind`/`getsockname`, and whatever Wine's
  unix side actually uses — verify) so the sandboxed process **never emits a real UDP packet**;
  datagrams travel to the helper over the local TCP link with their destination attached, and replies
  come back the same way with their true source address.
- **VLESS mode:** the helper carries UDP as **XUDP** (Xray's Mux.Cool packet addressing) inside the
  VLESS-over-TCP stream, so one game socket can talk to many destinations and receive replies from
  any peer (full-cone behaviour, needed for P2P and voice). Plain per-destination VLESS UDP is not
  enough.
- **SOCKS5 mode:** the helper uses standard UDP ASSOCIATE (loopback UDP hop to Xray).
- **HTTP CONNECT mode, or UDP not available upstream:** UDP is blocked. Never sent direct.
- **UDP/443 (QUIC) stays blocked** in every mode, so Steam's browser uses TCP (Xray's Vision flow
  rejects it by default anyway).
- ICMP and raw sockets: blocked.
- UI note next to the toggle: multiplayer and voice work but may feel laggier than direct, because UDP
  rides inside TCP.

### 6.6 Launch path and the kill switch

- When the proxy is **off**, launch exactly as upstream does (anti-goal: zero impact).
- When **on**: start the helper → wait until it's listening → launch Wine as
  `sandbox-exec -f <profile> <shim> <wine64 args…>`.
- **`sandbox-exec` is a SIP-protected binary, so macOS strips `DYLD_*` variables when launching it.**
  Therefore a tiny shim (ours, not SIP-protected) runs inside the sandbox, sets
  `DYLD_INSERT_LIBRARIES` from a non-DYLD variable, then `exec`s `wine64`. `wineserver` is spawned by
  Wine and inherits both the sandbox and the env.
- The sandbox profile denies outbound network except `127.0.0.1:PORT` and the Unix-domain sockets
  Wine and its integrations need (wineserver socket under the temp dir, upstream's Discord IPC bridge
  sockets). Everything else (files, GPU, input, audio) is allowed, so graphics and controllers behave
  as without the proxy. Verify the profile doesn't affect Metal/GPU on the M2 Air.
- Every place that launches a Wine process for a bottle must go through this path. In upstream today
  these include `Wine.swift` (`runProcess`, ~line 101 and ~876), `Wine+ProcessManagement.swift`
  (~45) and `Steam/SteamLauncher.swift` (~199) — the builder should centralise rather than patch each.
- Environment: proxy-related variables go in upstream's existing `featureRuntime` layer of
  `EnvironmentBuilder` (see `WineEnvironment.swift`).
- If the helper dies, the bottle loses network (sandbox), the app shows "Proxy down — bottle offline"
  and offers restart. It never relaunches the bottle unproxied on its own.
- Applies to everything run in the bottle, including Winetricks downloads — or Winetricks runs are
  clearly marked as going direct. Builder's call; must be honest in the UI.

### 6.7 UI (small)

- Settings → **Proxies**: list/add/edit/delete profiles; "Test" button that connects through the proxy
  and shows the exit IP.
- Bottle config → **Network** section: proxy picker (Off / profile), the UDP warning, and a live status
  (helper running, connections, last error).
- Follow upstream's SwiftUI style; no redesign of the rest of the app.

## 7. Rebrand (decided scope)

- App name **AnoWine**, own icon, own bundle IDs, own data/bottle/log locations so it never touches
  Whisky's bottles. *(Claude's call:)* owner's GitHub account is **HighStormPVP**; repo
  `HighStormPVP/AnoWine` (GitHub fork of frankea/Whisky); bundle ID prefix
  `io.github.highstormpvp.AnoWine` (replacing `com.franke.Whisky*`). The same prefix sets the
  Keychain service name, data folders, Sparkle appcast and runtime release URLs, and the URL scheme
  `anowine://` (upstream `whisky://` in `Whisky/Utils/QuickLaunch.swift`). Fix these before the
  first release — changing them later means migrating Keychain items and data.
- Repoint URLs: issues, Sparkle appcast (GitHub Pages of the AnoWine repo, own EdDSA key), runtime
  download (`DistributionConfig.swift`).
- Wine runtime: re-host upstream's published `Libraries.tar.gz` on AnoWine's GitHub releases rather
  than hot-linking frankea's. Keep upstream's checksum verification (with our own SHA-256, since the
  archive is repacked — see next point).
- **Rename the two Wine programs (owner's decision, "for now"):** in the re-hosted runtime,
  `wine64` → `anowine` and `wineserver` → `anowine-server` *(names are Claude's suggestion)*, so
  Activity Monitor shows AnoWine names. Point Wine at the renamed server via `WINESERVER`; point
  Winetricks at the renamed loader via its `WINE`/`WINESERVER` variables. Done as a scripted repack
  step in CI, not by hand. Nothing deeper is renamed (internal Wine files, registry keys, Wine's own
  dialogs, upstream code names like `Wine.swift`). **Verify on a CI runner early**; if any part of Wine
  still requires the original names, keep the originals and report back to the owner rather than
  patching Wine.
- Keep internal names (`WhiskyKit`, types, file layout) to minimise merge conflicts.
- Keep the "migrate from Whisky" feature if it comes for free; don't invest in it.

## 8. Testing (decided approach)

- **Unit tests** (CI, `swift test`): proxy settings decoding/defaults, fake-DNS mapping, SOCKS5 and HTTP
  CONNECT handshakes against an in-test fake proxy, sandbox profile generation.
- **Integration test on a macOS runner** (the key proof): a tiny Windows console `.exe` (cross-compiled
  with MinGW in CI) that resolves a hostname, opens a TCP connection, and does a UDP echo exchange with
  two different destinations. Run it under Wine in a proxied bottle against a **real `xray-core`**
  configured with a local VLESS inbound (and, separately, its SOCKS inbound) whose outbound goes to
  local test echo servers, and assert:
  1. the TCP connection and the hostname arrived via Xray;
  2. no DNS query left the machine (packet capture — runners have passwordless sudo);
  3. UDP echoes from both destinations come back (proves XUDP / full-cone handling);
  4. in VLESS mode, no UDP packet appears on any interface, loopback included;
  5. with the helper or Xray killed, TCP and UDP fail and nothing reaches the network;
  6. with the proxy **off**, the same exe connects directly (proves the zero-impact path still works).
  (Runners may need `softwareupdate --install-rosetta --agree-to-license`.)
- **Early hardware check on the M2 Air** *(Claude's call)*: GitHub runners are VMs without a usable
  GPU, so the first milestone ships a diagnostic build the owner runs on the M2 Air to confirm the
  sandbox profile doesn't affect Metal rendering or Steam's web helper. Until that passes, the proxy
  toggle stays behind a hidden flag.
- **Manual tests on the owner's M2 Air** each release: Steam installs, logs in, store renders,
  a game downloads and launches — with proxy off and on. Check exit IP inside Steam's browser.
- Upstream's existing test suite must keep passing.

## 9. Risks and known unknowns

| Risk | Why it matters | How we find out |
|---|---|---|
| Gcenx Wine binaries reject `DYLD_INSERT_LIBRARIES` (hardened runtime / library validation) | The whole interposer approach depends on it | **First task:** `codesign -dv` the runtime binaries and inject a hello-world dylib on a CI runner |
| Which Wine process calls `connect()` / `getaddrinfo()` | Decides where the library must be loaded and why DNS map lives in the helper | Same spike, with logging interposer |
| UDP interception fights Wine's socket model (Wine polls real socket fds in `wineserver` for async I/O) | Replacing a UDP fd with a stream to the helper may break readiness/overlapped I/O | Spike UDP early with the echo test exe; fallback is a Unix-domain datagram socketpair standing in for the UDP fd |
| Steam or games bypass libc (direct syscalls) | Interposer misses traffic | Sandbox still blocks it → breaks rather than leaks; acceptable |
| `sandbox-exec` deprecated by Apple | Kill switch mechanism could go away | Still works on macOS 15/26/27; revisit if removed |
| Rosetta limited from macOS 28 | Whole x86_64 Wine stack | Follow upstream / Gcenx / CodeWeavers' arm64 work; keep interposer universal |
| Upstream is a one-person project | Could stall | We can carry on independently; merges are a convenience |
| 8 GB RAM on M2 Air | Large games may not run | Test lighter titles; not a project defect |

## 10. Left to the builder

- Exact framing protocol between interposer and helper; helper's networking API.
- Fake-IP range and table lifetime.
- How the helper is packaged (separate executable in the app bundle vs. part of `WhiskyCmd`).
- Exact sandbox profile rules, as long as §6.6 holds.
- UI layout details within upstream's style.
- Order of work, except that the §9 injection spike comes first: if injection is impossible, stop and
  come back to the owner before building anything else. The sandbox/kill-switch spike sits right
  beside it.
- **Kill-switch fallback (owner's decision):** if `sandbox-exec` turns out to be unusable — it breaks
  Metal or Steam's web helper, can't contain `wineserver`, or a macOS update removes it — ship the
  proxy **without the kill switch** (interposer + helper only), with a clear warning in the UI that
  traffic may go direct if the proxy drops or a program bypasses the interceptor. Do not build a pf /
  privileged-helper or Network Extension alternative.
