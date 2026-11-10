# Ano Plan 2a — Proxy: TCP and DNS through the owner's Xray client

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A per-bottle Proxy setting that sends every TCP connection and DNS lookup of the bottle's Windows programs through the owner's local Xray client (SOCKS5 or HTTP CONNECT inbound), so Steam can log in, show the store and download. UDP is blocked, not tunnelled, and the UI says so.

**Architecture:** An x86_64 C interposer (`libano_net.dylib`) is loaded only into Ano's Wine programs. It redirects TCP `connect()` for non-loopback destinations to a helper listening on `127.0.0.1:<port>`, answers DNS with fake IPs the helper hands out (so hostnames are resolved by the proxy, never locally), blocks non-loopback UDP, and strips itself from any non-Wine program Wine starts. The helper is a Swift engine in WhiskyKit (`Proxy/`), run inside the app per proxied bottle (and as the `ano-proxy` command-line tool in CI); it speaks SOCKS5 or HTTP CONNECT to the owner's Xray client. Proxy-off bottles launch exactly as today.

**Tech Stack:** Swift 6 (WhiskyKit package, SwiftUI app), C (clang `-arch x86_64`), POSIX sockets, Keychain (Security framework), bash/Python test harness, real `xray-core` in CI, MinGW for the Windows test program, GitHub Actions `macos-15`.

**Spec:** `docs/superpowers/specs/2026-10-25-anowine-design.md` (§6). Evidence: `spikes/REPORT.md`.

**Scope (owner's decision 2026-11-10: proxy first, so Steam is reachable):** this plan is slice 1 of the proxy. Slice 2 (Plan 2b): UDP inside TCP (VLESS + XUDP, SOCKS5 UDP ASSOCIATE), VLESS profiles. Slice 3 (Plan 2c): `sandbox-exec` kill switch, after the owner's M2 check (`m2-sandbox-check.sh`), which this slice makes runnable because Steam gets network. Until 2c, the UI states there is no kill switch (spec §10 fallback, owner-approved).

## Global Constraints

- New user-visible names avoid "wine": helper `ano-proxy`, interposer `libano_net.dylib`, wrapper `ano-loader` (shadows the real one on PATH for proxied bottles only).
- Proxy off = zero impact: no `ANO_*` variable, no `DYLD_INSERT_LIBRARIES`, no wrapper, no listener (spec §4).
- `DYLD_INSERT_LIBRARIES` is set **only** on the process that execs the runtime's `ano-loader` or `ano-server`, never exported into a shell or given to a non-Wine program (spike finding: arm64e tools abort).
- Fail closed: with the proxy on, if the helper is unreachable, DNS fails and connects fail. Never fall back to direct.
- Loopback (`127.0.0.0/8`, `::1`) goes direct (Steam's local IPC needs it; it never leaves the Mac). Everything else, LAN included, goes through the proxy. IPv4-mapped IPv6 is treated as IPv4.
- UDP to non-loopback addresses is refused with `EACCES` (Steam falls back to TCP). DNS AAAA answers are never returned while proxied.
- Interposer is x86_64 (the runtime is x86_64 under Rosetta), built with `-mmacosx-version-min=10.15`.
- Secrets (proxy passwords) only in the Keychain, service `"\(Bundle.whiskyBundleIdentifier).proxy"`, account = profile UUID string. Never in settings files, environment variables or logs.
- Helper listens on `127.0.0.1` only.
- Swift files start with the exact upstream GPL header ("This file is part of Whisky."); lines ≤ 120; Swift 6 strict concurrency; package platform macOS 15.
- `Whisky/Localizable.xcstrings`: LF line endings, en-GB entry for every new key (`scripts/british-english.py`, then re-normalise LF), Ano wording (`rebrand_strings.py --check` must pass).
- CI only (dev machine is Windows): `gh -R HighStormPVP/AnoWine`; a task is done when its workflow run is green. RED is pushed and watched before GREEN.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Pushing to `main` of the fork is the established workflow; nothing is published (no release) in this plan.

### Wire protocol (interposer ⇄ helper) — exact, both sides implement it

Every request opens a new TCP connection to `127.0.0.1:$ANO_PROXY_PORT` and starts with the 4 bytes `ANO1`, then one type byte:

| Type | Request after type byte | Helper reply |
|---|---|---|
| `C` (0x43) connect | `atyp` (1: `1`=IPv4, `4`=IPv6), address (4 or 16 bytes), port (2, big-endian) | none; the connection becomes the data stream to that destination. Helper closes it if the upstream fails. |
| `R` (0x52) resolve | length (1, 1–253), hostname bytes (ASCII) | 4 bytes: fake IPv4 (big-endian); `0.0.0.0` = failure. Then close. |
| `P` (0x50) peer | port (2, big-endian): the client-side local port of an earlier `C` connection | `atyp` (1; `0` = unknown) + address + port (2). Then close. |

Fake IPs come from `198.18.0.0/15` (first `198.18.0.1`). A `C` to an address in that range with no mapping is closed without contacting the upstream. Hostnames are lower-cased, a trailing dot removed.

### Environment (set by the app for proxied bottles)

| Variable | Value |
|---|---|
| `ANO_PROXY_PORT` | helper port, or `0` if it could not start (interposer then fails everything closed) |
| `ANO_NET_LIB` | absolute path of `libano_net.dylib` |
| `ANO_WINE_DIR` | absolute path of the runtime's `Libraries/Wine` folder (exec targets under it keep the interposer) |
| `ANO_REAL_LOADER` | absolute path of the runtime's `ano-loader` (used by the wrapper) |

## Review Focus

1. **A `ano-server` started without the interposer** keeps serving a proxied bottle, and in Wine the server makes the TCP `connect()` (spike) → silent direct connections. Every path that can start the server for a proxied bottle (app launches, Terminal, Winetricks, Run in Terminal) must carry the interposer, and changing a bottle's proxy setting stops its running programs first. Tests: Task 6 (environment for every path), Task 8 (changing the setting stops the bottle).
2. **The interposer reaching a native macOS tool** (Steam opening a URL runs `/usr/bin/open`; `system()` runs `/bin/sh`) aborts it. Test: Task 5 native test spawns `/usr/bin/true` with `posix_spawn` and via `system()`.
3. **Helper unreachable falls back to the system resolver or a direct connect.** Test: Task 7 kills the helper and asserts DNS and TCP fail and no DNS or SYN packet leaves (tcpdump).
4. **Address classes:** `::ffff:192.0.2.1` on an IPv6 socket, LAN addresses, `0.0.0.0`, and unknown fake IPs must not go direct. Tests: Task 4 (unknown fake IP), Task 5 (mapped IPv6, LAN).
5. **Proxy off changes behaviour.** Test: Task 6 asserts no `ANO_*`/`DYLD_*` keys for a proxy-off bottle; Task 7 runs the Windows test program unproxied and it connects directly.

---

### Task 1: Proxy settings and profiles

**Files:**
- Create: `WhiskyKit/Sources/WhiskyKit/Proxy/BottleProxyConfig.swift`, `ProxyProfile.swift`, `ProxySecretStore.swift`, `ProxyProfileStore.swift`
- Modify: `WhiskyKit/Sources/WhiskyKit/Whisky/BottleSettings.swift` (new `proxyConfig` field, decoded with `decodeIfPresent ?? BottleProxyConfig()`, like `discordConfig`)
- Test: `WhiskyKit/Tests/WhiskyKitTests/ProxySettingsTests.swift`

**Interfaces:**
- Produces:
  - `public struct BottleProxyConfig: Codable, Equatable` — `enabled: Bool = false`, `profileID: UUID? = nil`, `lastPort: UInt16? = nil`; decoder tolerant of every key missing.
  - `BottleSettings`: `public var proxyEnabled: Bool`, `public var proxyProfileID: UUID?`, `public var proxyLastPort: UInt16?`.
  - `public enum ProxyKind: String, Codable, CaseIterable, Sendable { case socks5, httpConnect }`
  - `public struct ProxyProfile: Codable, Equatable, Identifiable, Sendable` — `id: UUID`, `name: String`, `kind: ProxyKind`, `host: String`, `port: UInt16`, `username: String`; `public static func newDefault() -> ProxyProfile` (name `"Xray"`, `.socks5`, `127.0.0.1`, `10808`, empty username).
  - `public protocol ProxySecretStore: Sendable { func password(for id: UUID) -> String?; func setPassword(_ password: String?, for id: UUID) throws }` and `public struct KeychainProxySecretStore: ProxySecretStore` (generic password, service and account per Global Constraints; `nil` deletes).
  - `@MainActor public final class ProxyProfileStore: ObservableObject` — `public static let shared` (file `WhiskyWineInstaller.applicationFolder/ProxyProfiles.json`, Keychain store); `public init(fileURL: URL, secrets: ProxySecretStore)`; `@Published public private(set) var profiles: [ProxyProfile]`; `public func save(_ profile: ProxyProfile, password: String?) throws`; `public func delete(id: UUID) throws` (also deletes the secret); `public func profile(id: UUID) -> ProxyProfile?`; `public func upstream(for id: UUID) -> ProxyUpstream?` (defined in Task 3; add it there).

- [ ] **Step 1: Write the failing tests** (`ProxySettingsTests`, XCTest, with an `InMemoryProxySecretStore` defined in the test file):
  - `testBottleSettingsWithoutProxyKeysDecodeProxyOff`: encode a default `BottleSettings`, remove `proxyConfig` from the plist dictionary, decode → `proxyEnabled == false`, `proxyProfileID == nil`.
  - `testProxySettingsRoundTrip`: set `proxyEnabled = true`, a profile UUID and `proxyLastPort = 51234`, encode/decode → equal.
  - `testProfileStorePersistsWithoutPassword`: save a profile with password `"s3cret"` → reload a new store from the same file → profile equal; the JSON file's bytes do not contain `s3cret`; the secret store returns `"s3cret"`.
  - `testDeletingProfileDeletesSecret`.
  - `testDefaultProfileIsLocalSocks`: `newDefault()` is `.socks5`, `127.0.0.1`, `10808`.
- [ ] **Step 2: Push; CI `Run Tests` fails on the missing types.**
- [ ] **Step 3: Implement** the files above.
- [ ] **Step 4: Push; CI green (whole WhiskyKit suite).**
- [ ] **Step 5: Commit** `feat: proxy settings per bottle and proxy profiles`.

### Task 2: Wire protocol and fake DNS

**Files:**
- Create: `WhiskyKit/Sources/WhiskyKit/Proxy/ProxyFrame.swift`, `FakeDNS.swift`
- Test: `WhiskyKit/Tests/WhiskyKitTests/ProxyFrameTests.swift`

**Interfaces:**
- Produces:
  - `public enum ProxyAddress: Equatable, Sendable { case ipv4(UInt32, port: UInt16); case ipv6([UInt8], port: UInt16); case domain(String, port: UInt16) }`
  - `public enum ProxyFrame: Equatable, Sendable { case connect(ProxyAddress); case resolve(String); case peer(localPort: UInt16) }` with `public func encoded() -> [UInt8]` and `public static func decode(_ bytes: [UInt8]) throws -> (ProxyFrame, consumed: Int)` (throws `ProxyFrameError.incomplete` when more bytes are needed, `.invalid` otherwise). `.connect` only carries `.ipv4`/`.ipv6` on the wire.
  - `public final class FakeDNS: @unchecked Sendable` — `public init(range: ClosedRange<UInt32> = 0xC612_0001...0xC613_FFFE)`; `public func address(for name: String) -> UInt32?` (normalises; `nil` for empty, > 253 bytes, or non-ASCII); `public func name(for address: UInt32) -> String?`; `public func contains(_ address: UInt32) -> Bool` (in `198.18.0.0/15`). Thread-safe (lock).

- [ ] **Step 1: Failing tests:** byte-exact encodings, e.g. `ProxyFrame.connect(.ipv4(0xC0000201, port: 7000)).encoded() == Array("ANO1".utf8) + [0x43, 1, 192, 0, 2, 1, 0x1B, 0x58]`; `.resolve("Steam.com.")` encodes `"steam.com"` length 9; `.peer(localPort: 513)` → `[... 0x50, 0x02, 0x01]`; decode of each round-trips; decode of a prefix throws `.incomplete`; bad magic throws `.invalid`; `FakeDNS`: same name twice → same address, `"A.example."` and `"a.example"` same, two names differ, first address `0xC6120001`, `name(for:)` reverses, unknown → `nil`, `contains(0xC6130000) == true`, `contains(0xC6140000) == false`.
- [ ] **Step 2: Push; RED.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Push; green.**
- [ ] **Step 5: Commit** `feat: proxy wire protocol and fake DNS`.

### Task 3: Upstream handshakes (SOCKS5, HTTP CONNECT)

**Files:**
- Create: `WhiskyKit/Sources/WhiskyKit/Proxy/ProxyUpstream.swift`, `ProxySocket.swift` (small POSIX helpers: connect with timeout, read exactly, write all)
- Modify: `ProxyProfileStore.swift` (`upstream(for:)`)
- Test: `WhiskyKit/Tests/WhiskyKitTests/ProxyUpstreamTests.swift` (fake servers on `127.0.0.1:0` in the test, POSIX or `NWListener`)

**Interfaces:**
- Produces:
  - `public enum ProxyUpstream: Equatable, Sendable { case socks5(host: String, port: UInt16, username: String?, password: String?); case httpConnect(host: String, port: UInt16, username: String?, password: String?) }`
  - `public func open(to destination: ProxyAddress, timeout: TimeInterval = 15) throws -> Int32` — returns a connected, blocking file descriptor positioned after the handshake; throws `ProxyError` (`.unreachable`, `.refused(String)`, `.authFailed`, `.protocolError(String)`).
  - SOCKS5 (RFC 1928/1929): offer method `0x00`, plus `0x02` when a username is set; `ATYP 3` for `.domain`, `1` for `.ipv4`, `4` for `.ipv6`.
  - HTTP: `CONNECT host:port HTTP/1.1` + `Host:` + `Proxy-Authorization: Basic …` when a username is set; success on any `2xx` status line; IPv6 hosts bracketed.

- [ ] **Step 1: Failing tests:** against an in-test fake SOCKS5 server that records the request and then echoes: `.domain("steam.example", port: 443)` sends `05 01 00 03 0d "steam.example" 01 bb`; with credentials the server sees method 2 and `01 05 "alice" 06 "secret"`; server reply `05 05` → `ProxyError.refused`; auth reply `01 01` → `.authFailed`; data written after `open` comes back (echo). Fake HTTP server: request line `CONNECT steam.example:443 HTTP/1.1`, Basic header `YWxpY2U6c2VjcmV0`, `HTTP/1.1 403` → `.refused`; nothing listening → `.unreachable`.
- [ ] **Step 2: Push; RED.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Push; green.**
- [ ] **Step 5: Commit** `feat: SOCKS5 and HTTP CONNECT upstreams`.

### Task 4: Helper engine, proxy service, `ano-proxy` tool

**Files:**
- Create: `WhiskyKit/Sources/WhiskyKit/Proxy/ProxyListener.swift`, `ProxyService.swift`, `WhiskyKit/Sources/ano-proxy/main.swift`
- Modify: `WhiskyKit/Package.swift` (add `.executable(name: "ano-proxy", targets: ["ano-proxy"])` and `.executableTarget(name: "ano-proxy", dependencies: ["WhiskyKit"])`)
- Test: `WhiskyKit/Tests/WhiskyKitTests/ProxyListenerTests.swift`

**Interfaces:**
- Consumes: Task 2 `ProxyFrame`, `FakeDNS`; Task 3 `ProxyUpstream.open`.
- Produces:
  - `public struct ProxyStatus: Equatable, Sendable { public var port: UInt16; public var activeConnections: Int; public var totalConnections: Int; public var lastError: String? }`
  - `public final class ProxyListener: @unchecked Sendable` — `public init(upstream: ProxyUpstream)`; `public func start(preferredPort: UInt16?) throws -> UInt16` (binds `127.0.0.1`; tries `preferredPort`, falls back to `0`; returns the port synchronously); `public func stop()`; `public var status: ProxyStatus`. One thread accepts; each connection runs on its own thread: decode a frame; `R` → reply from `FakeDNS`; `P` → reply from the local-port table; `C` → map fake IP to `.domain(name, port)` (close if the fake IP is unknown), `upstream.open`, record `clientPort → destination`, then copy both directions until either side closes (64 KiB buffers), then forget the port.
  - `@MainActor public final class ProxyService: ObservableObject` — `public static let shared`; `public func port(for bottle: Bottle) -> UInt16?` (starts a listener for the bottle's profile if none runs, preferring `bottle.settings.proxyLastPort`, stores the port back into `proxyLastPort`; `nil` if the profile is missing or binding fails); `public func status(for bottle: Bottle) -> ProxyStatus?`; `public func stop(bottleURL: URL)`; `public func restart(for bottle: Bottle)` (profile edited). Uses `ProxyProfileStore.shared.upstream(for:)`.
  - `ano-proxy`: `ano-proxy (--socks5|--http) HOST:PORT [--user U] [--password-env VAR] [--port N]` prints `listening <port>` on stdout, flushes, writes one `accepted <C|R|P>` line per request to stderr, runs until SIGTERM/SIGINT.

- [ ] **Step 1: Failing tests** (in-process: a fake SOCKS5 upstream that records the requested address and echoes, plus a `ProxyListener` on port 0):
  - `testResolveThenConnectSendsHostnameUpstream`: frame `R "anotest.example.com"` → 4-byte fake IP in `198.18.0.0/15`; frame `C` to that IP port 7000 then `"PING\n"` → upstream saw ATYP 3 `anotest.example.com` port 7000, and `"PING\n"` echoes back.
  - `testConnectToPlainIPv4UsesIPv4`: `C` to `192.0.2.1:7000` → upstream saw ATYP 1.
  - `testUnknownFakeAddressIsClosedWithoutUpstream`: `C` to `198.18.200.1:80` → connection closed, upstream saw no request, `status.lastError` set.
  - `testPeerReturnsOriginalDestination`: during an open `C` connection, `P <client local port>` → `.ipv4(192.0.2.1, 7000)`.
  - `testPreferredPortIsReused` and `testBusyPreferredPortFallsBack`.
  - `testUpstreamDownClosesClient`: upstream unreachable → client connection closed, `lastError` mentions it.
- [ ] **Step 2: Push; RED.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Push; green. Also `swift build --package-path WhiskyKit --product ano-proxy` succeeds (add it to the CI `Build WhiskyKit` step).**
- [ ] **Step 5: Commit** `feat: proxy helper engine and ano-proxy tool`.

### Task 5: Interposer `libano_net.dylib` and its native test

**Files:**
- Create: `AnoNet/ano_net.c`, `AnoNet/README.md` (what it hooks, the wire protocol pointer), `scripts/anowine/tests/interposer_native.c`, `scripts/anowine/tests/echo_servers.py` (moved from `spikes/echo_servers.py`), `scripts/anowine/tests/xray-test.json`, `scripts/anowine/check-proxy.sh`, `.github/workflows/AnoProxy.yml`
- Modify: `scripts/anowine/check-hygiene.sh` glob already covers `scripts/anowine/*.sh`; nothing else.

**Interfaces:**
- Consumes: wire protocol, environment table (Global Constraints); Task 4 `ano-proxy`.
- Produces: `libano_net.dylib` (x86_64), hooking via `__DATA,__interpose`. Every hook is a pass-through when `ANO_PROXY_PORT` is unset.
  - `getaddrinfo`: numeric host or `NULL` node or `localhost`/`*.localhost` → real call. Otherwise `R` to the helper; failure → `EAI_FAIL` (never the real resolver). Success → result of the real `getaddrinfo` on the fake IP's dotted string with `AI_NUMERICHOST` and `ai_family = AF_INET` (so `freeaddrinfo` stays native); hints asking for `AF_INET6` only → `EAI_NONAME`.
  - `gethostbyname`, `gethostbyname2`: same rule, IPv4 only, static `hostent`.
  - `connect`: `AF_INET`/`AF_INET6` stream socket to a non-loopback destination (mapped IPv6 treated as IPv4) → real connect to `127.0.0.1:port` (`::ffff:127.0.0.1` on IPv6 sockets) with the socket made blocking for that call and its flags restored, send the `C` frame, return 0. Helper unreachable → `-1`/`ECONNREFUSED`. Datagram socket to a non-loopback destination → `-1`/`EACCES`.
  - `sendto`, `sendmsg`: datagram socket with a non-loopback destination → `-1`/`EACCES`.
  - `getpeername`: if the real peer is `127.0.0.1:$ANO_PROXY_PORT`, ask the helper with `P <local port>` and return the original destination.
  - `execve`, `posix_spawn`, `posix_spawnp`: if the target path does not start with `$ANO_WINE_DIR/`, pass an environment without `DYLD_INSERT_LIBRARIES` (other `ANO_*` kept).
- `check-proxy.sh <runtime-Libraries-dir|-> <ano-proxy> <dylib> <netprobe.exe|-> <interposer_native>`: starts echo servers (TCP 7000; UDP 7001/7002 on 127.0.0.1), `xray` with `xray-test.json` (SOCKS inbound `127.0.0.1:10808`; `dns.hosts` maps `anotest.example.com` → `127.0.0.1`; routing sends `192.0.2.1` to a `freedom` outbound with `redirect: 127.0.0.1:7000`; access log to a file), `ano-proxy --socks5 127.0.0.1:10808`, and `sudo tcpdump` on `lo0` and the default interface capturing `udp port 53 or host 192.0.2.1 or host 192.0.2.2`. Prints `ok`/`FAIL` lines like `check-ano-programs.sh`, exits non-zero on any `FAIL`.
- `AnoProxy.yml` (push to `main` on paths `AnoNet/**`, `WhiskyKit/Sources/WhiskyKit/Proxy/**`, `WhiskyKit/Sources/ano-proxy/**`, `scripts/anowine/tests/**`, `scripts/anowine/check-proxy.sh`, itself; and `workflow_dispatch`), `macos-15`: Rosetta; download Xray `v26.10.21` `Xray-macos-arm64-v8a.zip`, verify SHA-256 `926cc55fda2a8757dabe4f22dc98772f218ace025f101bd0b68aee232e59d5dc`; `clang -arch x86_64 -dynamiclib -O2 -Wall -Werror -mmacosx-version-min=10.15 -o libano_net.dylib AnoNet/ano_net.c`; `clang -arch x86_64 -O2 -o interposer_native scripts/anowine/tests/interposer_native.c`; `swift build -c release --package-path WhiskyKit --product ano-proxy`; run `check-proxy.sh` (Task 7 adds the Wine part).

- [ ] **Step 1: Write the failing native test** `interposer_native.c` (run under Rosetta with `DYLD_INSERT_LIBRARIES`, `ANO_PROXY_PORT`, `ANO_WINE_DIR=/nonexistent`), one `ok`/`FAIL` line per check:
  1. `getaddrinfo("anotest.example.com")` → one IPv4 in `198.18.0.0/15`.
  2. TCP connect to that address, port 7000, `"PING\n"` echoes; `getpeername` returns the fake IP and port 7000.
  3. TCP connect to `192.0.2.1:7000` echoes (via Xray redirect).
  4. IPv6 socket, connect to `::ffff:192.0.2.1` port 7000, echoes (proxied, not direct).
  5. UDP `sendto` `192.0.2.1:7001` → `-1` with `EACCES`; UDP `connect` to `192.0.2.2:7002` → `-1`/`EACCES`; UDP to `127.0.0.1:7001` works (loopback).
  6. TCP connect to `127.0.0.1:7000` direct works.
  7. `posix_spawn("/usr/bin/true")` exits 0; `system("/usr/bin/true")` returns 0.
  8. With `ANO_PROXY_PORT` pointing at a closed port (child re-run with `--helper-down`): `getaddrinfo` fails, TCP connect to `192.0.2.1:7000` fails.
  `check-proxy.sh` also asserts: Xray's access log contains `anotest.example.com:7000`; tcpdump saw no packet to `192.0.2.1`/`192.0.2.2` on the default interface and no DNS query containing `anotest`.
- [ ] **Step 2: Push the test, script, workflow and an `ano_net.c` that compiles but hooks nothing; the run fails on checks 1–5 and 8 (not on 6 and 7).**
- [ ] **Step 3: Implement `ano_net.c`.**
- [ ] **Step 4: Push; `AnoProxy` green.**
- [ ] **Step 5: Commit** `feat: libano_net interposer with native test against real Xray`.

### Task 6: Launch path — only Wine gets the interposer

**Files:**
- Create: `WhiskyKit/Sources/WhiskyKit/Proxy/ProxyEnvironment.swift`
- Modify: `WhiskyKit/Sources/ano-proxy/main.swift` (`--write-wrapper DIR`: calls `ProxyEnvironment.installWrapper(in:)` and exits), `WhiskyKit/Sources/WhiskyKit/Wine/WineEnvironment.swift` (proxied bottle → `ProxyEnvironment.variables(...)` in the `featureRuntime` layer), `Wine/Wine.swift` (`runProcess` passes `environment` through `ProxyEnvironment.launchEnvironment(_:executable:)`; `generateRunCommand(at:...)` and `generateRunCommand(for:)` run the wrapper instead of `wineBinary` when `ANO_PROXY_PORT` is present; `generateTerminalEnvironmentCommand(binFolder:environment:)` puts the wrapper folder before the bin folder on `PATH` when `ANO_PROXY_PORT` is present and never prints `DYLD_INSERT_LIBRARIES`), `Whisky/Utils/Winetricks+Install.swift`, `Winetricks+InstalledVerbs.swift`, `Winetricks.swift` (proxied bottle: add the four `ANO_*` variables and set `WINE` to the wrapper path)
- Test: `WhiskyKit/Tests/WhiskyKitTests/ProxyEnvironmentTests.swift`

**Interfaces:**
- Consumes: Task 1 settings, Task 4 `ProxyService.port(for:)`.
- Produces (`public enum ProxyEnvironment`):
  - `static let portKey = "ANO_PROXY_PORT"`, `libraryKey = "ANO_NET_LIB"`, `wineDirKey = "ANO_WINE_DIR"`, `realLoaderKey = "ANO_REAL_LOADER"`.
  - `public static func variables(port: UInt16?, library: URL, wineFolder: URL, realLoader: URL) -> [String: String]` (`port nil` → `"0"`).
  - `public static func launchEnvironment(_ environment: [String: String], executable: URL) -> [String: String]` — adds `DYLD_INSERT_LIBRARIES = environment[libraryKey]` only when that key is non-empty and `executable` is `AnoWineRuntime.loaderURL` or `serverURL` (compare standardized paths); otherwise returns `environment` with any `DYLD_INSERT_LIBRARIES` removed.
  - `public static var libraryURL: URL` — `ANO_NET_LIB_PATH` environment override, else `Bundle.main` resource `libano_net.dylib`, else `Contents/Resources/libano_net.dylib` relative to the running executable's app bundle (covers the bundled CLI).
  - `public static func installWrapper(in folder: URL = WhiskyWineInstaller.applicationFolder.appending(path: "Proxy/bin")) throws -> URL` — writes `folder/ano-loader` (mode 755), exactly:
    ```sh
    #!/bin/sh
    # Ano: start Wine with the proxy interceptor. Only Wine gets it.
    DYLD_INSERT_LIBRARIES="$ANO_NET_LIB" exec "$ANO_REAL_LOADER" "$@"
    ```
- [ ] **Step 1: Failing tests:**
  - `testProxyOffBottleHasNoProxyOrDyldKeys` (no key starting with `ANO_` or `DYLD_` from `constructWineEnvironment`).
  - `testProxiedBottleGetsVariablesWithoutDyld` (bottle with `proxyEnabled` and a profile in an injected store; keys present, `DYLD_INSERT_LIBRARIES` absent).
  - `testDyldOnlyForLoaderAndServer`: `launchEnvironment` with `ANO_NET_LIB` set → present for `loaderURL` and `serverURL`, absent for `/usr/bin/env` and for `/bin/sh`; an incoming `DYLD_INSERT_LIBRARIES` is removed for `/usr/bin/env`.
  - `testTerminalForProxiedBottleShadowsLoaderAndNeverExportsDyld` (PATH starts with the wrapper folder; output has no `DYLD_`).
  - `testRunCommandForProxiedBottleUsesWrapper`.
  - `testWrapperScriptIsExact` (content and mode 755).
- [ ] **Step 2: Push; RED.**
- [ ] **Step 3: Implement.** `ProxyService` must be injectable for tests (`constructWineEnvironment` takes `proxyPort: (Bottle) -> UInt16? = { ProxyService.shared.port(for: $0) }` defaulted).
- [ ] **Step 4: Push; green (full suite, SwiftLint).**
- [ ] **Step 5: Commit** `feat: proxied bottles launch Wine with the interceptor, nothing else`.

### Task 7: Windows-side integration test under Wine

**Files:**
- Create: `scripts/anowine/tests/netprobe.c` (from `spikes/netprobe/netprobe.c`, plus mode `peer <host> <port>`: connect, print `getpeername` as `ip:port`)
- Modify: `scripts/anowine/check-proxy.sh` (Wine part), `.github/workflows/AnoProxy.yml` (build `netprobe.exe` with Homebrew `mingw-w64`: `x86_64-w64-mingw32-gcc -O2 -o netprobe.exe netprobe.c -lws2_32`; download runtime `v3.1.5` `Libraries.tar.gz`, verify SHA-256 `4ce4a504fd368c8ac88fe5cacd64bd1a05bdc40c88dd222469fae35140117f5b`, cache by digest; `ano-proxy --write-wrapper`)

- [ ] **Step 1: Failing checks** (Wine runs through the wrapper with the four `ANO_*` variables, new prefix, `WINEDEBUG=-all`):
  1. `netprobe dns anotest.example.com` prints an address in `198.18.0.0/15`.
  2. `netprobe tcp anotest.example.com 7000` → exit 0; Xray access log has `anotest.example.com:7000`.
  3. `netprobe tcp 192.0.2.1 7000` → exit 0.
  4. `netprobe peer 192.0.2.1 7000` prints `192.0.2.1:7000`.
  5. `netprobe udp 192.0.2.1 7001 192.0.2.2 7002` → exit 1; no UDP packet to `192.0.2.0/24` in the capture.
  6. No DNS packet containing `anotest` on any captured interface during 1–5.
  7. `ano-proxy` killed → `netprobe tcp anotest.example.com 7000` and `netprobe tcp 192.0.2.1 7000` exit 1; still no DNS/SYN in the capture. (Restart `ano-server` between phases: `ano-server -k; ano-server -w`.)
  8. Proxy off (new prefix, no `ANO_*`, the real `ano-loader`, helper running): `netprobe tcp 127.0.0.1 7000` → exit 0, and `ano-proxy` wrote no `accepted` line during this phase.
- [ ] **Step 2: Push the Wine phase with these assertions; RED** (expected failures show what Wine does differently from the native test — e.g. which process calls `getpeername`).
- [ ] **Step 3: Make it pass** (fix interposer/helper defects found here; record each in `spikes/REPORT.md` under a new "Plan 2a" heading).
- [ ] **Step 4: Push; `AnoProxy` green.**
- [ ] **Step 5: Commit** `test: Windows program under Wine reaches the network only through Xray`.

### Task 8: Ship the interposer in the app; settings UI

**Files:**
- Modify: `Whisky.xcodeproj/project.pbxproj` — new `PBXShellScriptBuildPhase` "Build Ano network interceptor" in the app target, before "Copy Bundle Resources" ends (inputs `$(SRCROOT)/AnoNet/ano_net.c`, output `$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/libano_net.dylib`), script: the Task 5 `clang` line writing to the output path, then `codesign --force --sign - "<output>"`. Keep the IDs unique; check `ENABLE_USER_SCRIPT_SANDBOXING` allows the declared output.
- Modify: `.github/workflows/AnoWineTestBuild.yml` — after the build, fail unless `Ano.app/Contents/Resources/libano_net.dylib` exists and `lipo -archs` prints `x86_64`.
- Create: `Whisky/Views/Settings/ProxySettingsSection.swift` (list, add/edit sheet, delete, Test), `Whisky/Views/Bottle/NetworkConfigSection.swift`
- Modify: `Whisky/Views/Settings/SettingsView.swift` (add `ProxySettingsSection()`), `Whisky/Views/Bottle/ConfigView.swift` (add `NetworkConfigSection(bottle:)` after `DiscordConfigSection`), `Whisky/Localizable.xcstrings`
- Test: `WhiskyKit/Tests/WhiskyKitTests/ProxyServiceTests.swift` (`testChangingProxySettingStopsBottle` with an injected stopper), app UI test only if an existing pattern covers Settings sections

**Behaviour and copy (en; en-GB via the script):**
- Settings → section `settings.proxies` "Proxies", footer `settings.proxies.info` "Ano sends a bottle's traffic through a proxy client you already run, such as Xray. Ano doesn't include a proxy server." Rows: name, `host:port`, type. Buttons `settings.proxies.add` "Add Proxy…", `settings.proxies.delete` "Delete", `settings.proxies.test` "Test". Test fetches `https://www.cloudflare.com/cdn-cgi/trace` through the profile (`URLSessionConfiguration.connectionProxyDictionary`) and shows `settings.proxies.test.result` "Exit IP: %@" or `settings.proxies.test.failed` "Couldn't connect: %@".
- Edit sheet fields: `proxy.name` "Name", `proxy.kind` "Type" (`proxy.kind.socks5` "SOCKS5", `proxy.kind.http` "HTTP (CONNECT)"), `proxy.host` "Host", `proxy.port` "Port", `proxy.username` "Username (optional)", `proxy.password` "Password (optional)". Saving an edited profile calls `ProxyService.shared.restart` for bottles using it.
- Bottle → section `config.network` "Network": picker `config.network.proxy` "Proxy" with `config.network.proxy.off` "Off" and one entry per profile (disabled with `config.network.proxy.none` "Add a proxy in Settings → Proxies first." when there are none). When on, three caption lines: `config.network.proxy.udp` "UDP is blocked while the proxy is on, so voice chat and some multiplayer games won't work yet."; `config.network.proxy.killswitch` "There's no kill switch yet: a program that bypasses Ano's interceptor could connect directly."; `config.network.proxy.winetricks` "Winetricks downloads its files without the proxy." Status line: `config.network.status.running` "Running on port %1$d · %2$d open connections", or `config.network.status.offline` "Not running. This bottle has no internet until the proxy starts.", plus `config.network.status.error` "Last error: %@".
- Changing the picker while the bottle has running programs asks `config.network.restart.title` "Close this bottle's programs?" / `config.network.restart.message` "The new network setting only applies to programs started after this. Ano closes the bottle's programs now so nothing keeps the old setting." / `config.network.restart.confirm` "Close Programs"; cancel reverts the picker. Confirm stops the bottle (existing kill path), then `ProxyService.shared.stop(bottleURL:)`.

- [ ] **Step 1: Failing tests:** `testChangingProxySettingStopsBottle`; test-build check for the dylib (push → `AnoWineTestBuild` fails).
- [ ] **Step 2: Push; RED.**
- [ ] **Step 3: Implement** the build phase, views and strings; run `scripts/british-english.py`, normalise LF, `rebrand_strings.py --check`.
- [ ] **Step 4: Push; CI, Hygiene, Localization and Test Build green.**
- [ ] **Step 5: Commit** `feat: proxy settings UI and the interceptor in the app bundle`.

### Task 9: Owner build and docs

**Files:**
- Modify: `README.md` (Proxy section: what it covers, what it doesn't yet — UDP, kill switch, Winetricks downloads, and programs started with the `ano` command-line tool have network only while that command runs — and how to find the SOCKS/HTTP port of an Xray client), `docs/anowine/TESTING-ON-M2.md` (proxy steps; `m2-sandbox-check.sh` now works from a proxied bottle's Open Terminal because the wrapper carries the interceptor into both rounds), `CLAUDE.md` status (workspace file, not in the repo).

- [ ] **Step 1:** Download the green `Ano-test` artifact, check `libano_net.dylib` is inside, rename `Ano-6.zip`, send it with the install line from `CLAUDE.md` and three steps: add the Xray client's SOCKS (or HTTP) port in Settings → Proxies, press Test, turn the proxy on for the Steam bottle.
- [ ] **Step 2: Commit** `docs: proxy (slice 1) usage and limits`.
