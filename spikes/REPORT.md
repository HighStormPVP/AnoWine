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

> **2026-11-04:** the programs are now named `ano-loader` and `ano-server` (runtime v3.1.3). The spike below ran with the earlier names `anowine` / `anowine-server`; the recipe is unchanged.

> **2026-11-10: loader renamed `ano-core` (runtime v3.1.4).** The process every Windows program runs in is `lib/wine/x86_64-unix/wine`, started by `bin/ano-loader` through ntdll.so. Wine 11.0's `loader/main.c` never names itself (it loads `ntdll.so` from its own folder); ntdll.so names it, in `dlls/ntdll/unix/loader.c` lines 466 and 497. So the rename is the file plus an ntdll.so rebuilt with `scripts/anowine/patches/ntdll-ano-core.patch` (`scripts/anowine/build-ntdll.sh`, x86_64 under Rosetta, like the whole runtime).
> - Which source the shipped ntdll.so came from: plain Wine 11.0. Built side by side, Gcenx's later `llvm-mingw_fixes.patch` adds 36 syscall-wrapper stubs; the shipped ntdll.so has 0, as does the plain build. All builds export the same 287 symbols as the shipped one.
> - Smoke test (`scripts/anowine/check-ano-core.sh --boot`): before, every Wine process had kernel name `wine`; after, every one (64-bit and syswow64) is `ano-core`, and wineboot succeeds.

> **2026-11-10: `wineboot.exe` → `ano-boot.exe`, `winedevice.exe` → `ano-device.exe` (runtime v3.1.5).** References by file name, found in the source (including ntdll's char-array strings) and confirmed by scanning every runtime file for the names as ASCII and UTF-16: ntdll.so (starts the boot program for every new session, `dlls/ntdll/unix/env.c`), user32.dll x64+x86 (`ExitWindowsEx`), services.exe (driver host), winedbg.exe x64+x86 (crash dialog), wineboot itself (64-bit restart) and wine.inf (installs both into bottles). No registry key names either file: services.exe's `Winedevice<n>` driver-host entries are in-memory only (now `AnoDevice<n>`). Kept on purpose, as they are not file names: the `__wineboot_event` object (ntdll and ano-boot must agree), `WINEBOOTSTRAPMODE`, the `wineboot` debug channel and the manifest name. `scripts/anowine/patches/ano-programs.patch`, built by `build-modules.sh`; the built wine.inf differs from upstream's in exactly the two install lines.
> - Outside Wine: the app's prefix repair and Open Terminal aliases, and the app's winetricks (`"${WINE}" wineboot` when creating a bottle).
> - `check-ano-programs.sh`: before, every check failed; after, all pass — new bottle (both programs run, neither old name runs or is installed, MountMgr RUNNING), user32 `ExitWindowsEx` starts ano-boot.exe, a v3.1.4 bottle updates (ano-boot runs, both installed, drivers still run), winetricks creates a bottle.

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

## Plan 2a: findings from the proxy test under Wine

Found by `scripts/anowine/check-proxy.sh` (workflow `Ano Proxy`), fixed in `AnoNet/ano_net.c`.

- **A new proxied bottle did not boot** (`Unhandled exception 0xc0000417`, then
  `could not load kernel32.dll, status c0000135`; run 42894914225). While it creates a
  bottle, Wine looks up the Mac's own hostname and asks for the canonical name. The
  interposer answered with a placeholder address and no name. Fix: the Mac's own
  hostname and `.local` names are resolved locally (they never go to an internet DNS
  server), and a lookup with `AI_CANONNAME` gets the name back. Green in run 42901992812.
- Wine connects TCP sockets inside `ano-server`, so the server needs the interposer
  too, not only the loader. Both get it.
- **A reverse lookup leaked** (final review; run 42919774948 captured
  `PTR? 9.2.0.192.in-addr.arpa` going to the runner's DNS server). `gethostbyaddr`
  does not go through `getaddrinfo`. It is now refused, with `res_query` and friends
  and the `DNSService` lookups. Those two did not leak in the capture (the UDP block
  already stopped them), but they are refused as well.
- Windows programs see blocked UDP as `WSAEACCES` (10013) and a missing helper as
  `WSAECONNREFUSED` (10061) or a failed lookup (11003).

## Plan 3a: Wine program start-up on runtime 4.9.0

On runtime 4.9.0 the trace scan's winetricks steps hit their time limits. They finished
on 3.1.6. The ps snapshots showed each Wine process taking about 4 s to appear. A
program therefore reaches the server after the server's 3 s idle exit, and every
winetricks Wine call boots the prefix again. The `Ano Engine Timing` workflow
(dispatch only; run 44285254299, macos-15 runners) measured three runtimes:

| Wall time | Ano 3.1.6 | Ano 4.9.0 | upstream 4.8.3 |
|---|---|---|---|
| `cmd /c echo hi`, server kept up (`-p`) | ~1.0 s | ~8.1 s | ~10.3 s |
| same, no persistent server (each call reboots on 4.x) | ~1.2 s | ~33 s | ~44 s |
| create a prefix (`ano-boot`/`wineboot --init`) | 40 s | 114 s | 124 s |
| `--version` | ~0.2 s | ~0.2 s | ~0.2 s |

A `+timestamp,+process` trace shows about 3.5 s of Mac-side start-up in each process
before any Windows code runs. `start.exe` pays it, and then `cmd.exe` pays it again.
Upstream's unmodified engine is as slow, so Ano's repack is not the cause. Whether
real Macs are slow too is unknown: CI runners are virtual Macs with a paravirtual GPU
and no display. The owner's Ano-8 test (item 7) measures it on the M2. For Plan 3c's
inventory, the trace scan should keep a persistent server (`ano-server -p`) during
its winetricks steps.

## Plan 3b: Ano builds the engine

`scripts/anowine/build-engine.sh` (workflow `Ano Engine`, dispatch only) builds upstream's
GPTK engine v4.8.3 from source on a macos-15 runner: Wine 11.19 with CrossOver's patches
(dappermint/winecx `9f3f644`), upstream's recipe files fetched at frankea/winecx-gptk
`12af865` with SHA-256 checks (they have no license, so they are not stored here), and
x86_64 libraries from nixpkgs `ac62194c`. Job `check` compares the result file by file with
upstream's published `Libraries.tar.gz` (`scripts/anowine/compare_runtimes.py`).

**Result** (build run 44511381580, check run 44528033062): `compare_runtimes.py` exit 2, "equal to upstream's v4.8.3 only by interface": 5,968 files, 4,383 byte-identical, 1,514 differing only in timestamps, 70 only in an unused export table, 1 expected (Ano's README), 0 different, none missing on either side; the version plist is byte-identical. Both self-checks passed (upstream equals itself; Ano 4.9.0 differs from upstream in its 8 renamed modules). The check waited for a macOS runner through 29 dropped attempts.

Every file that is not byte-identical, and why:

| Files | Class | Cause |
|---|---|---|
| 1,513 PE and Mach-O files | timestamps | link times, PE checksums and ld's CodeView build ID (a hash of the link output, different on every link) |
| `x86_64-unix/lsteamclient.so` | timestamps | its 219 objects are the only ones compiled with `-g`, so ld64 writes each object's path and modification time into the debug map (N_OSO) and hashes them into LC_UUID and the ad-hoc signature's identifier. With those zeroed it is byte-identical to upstream's. The paths are absolute, so the engine is built in upstream's own folder (`/Users/runner/work/winecx-gptk/winecx-gptk`). |
| 70 FAudio DLLs (35 names, i386 and x86_64: `xaudio2_*`, `x3daudio1_*`, `xactengine*`, `xapofx1_*`) | interface | FAudio marks its API `dllexport`, so ld writes a second export directory that nothing points at, stamped with the link time. Code, data, imports and exports are equal. Not normalized away: that would widen the comparator for one stray table. |
| `lib/external/README` | expected | Ano's own text |

Build time per phase (seconds). Run 2 was cold (ccache 1.5% hits), run 3 warm (99.7%):

| Phase | Cold | Warm |
|---|---|---|
| fetch_sources | 26 | 17 |
| nix_inputs | 107 | 111 |
| build_tools | 72 | 65 |
| build_sdl2 | 59 | 52 |
| configure_wine | 55 | 40 |
| make_wine | 3325 | 829 |
| fetch_payloads | 13 | 12 |
| install_tree | 21 | 1779 |
| bundle_libraries | 148 | 159 |
| verify_tree | 73 | 70 |
| smoke_test | 328 | 340 |
| package | 52 | 56 |
| total | 4285 | 3535 |

The warm `install_tree` relinked 1541 of 1579 modules: with `CCACHE_FILECLONE` (upstream's
setting) a cache hit is a clone that keeps the cached file's old modification time, so
`make install-lib` saw every object as stale. The script now copies hits instead; the next
warm build shows the saving.

Tools next to upstream's run (43653944195): same Xcode 16.4 (SDK 15.5, clang-1700.0.13.5),
Homebrew mingw-w64 14.0.0_3 (gcc 16.2.0, binutils 2.47.20260726), cmake 4.4.5, nix 2.35.4.
Run 3 got upstream's runner image (macos15 20261104); run 2 had 20261112. Our ccache 4.14.2
to 4.14.3; upstream's version is not recorded.

**"wine" tokens** (`scripts/anowine/wine_tokens.py`, the starting point for Plan 3c's gate),
in our engine and a new bottle made with it, before the allowlist: 41,653 distinct tokens,
667,221 occurrences. Engine: 174 in names, 324,248 in ASCII text, 9,286 in UTF-16 text.
Bottle: 56 in names, 324,434 ASCII, 9,023 UTF-16. Most frequent: Wine 15,642,
wine_dbg_log 15,240, wine 13,981, __wine_dbg_output 8,783, __wine_dbg_header 8,773,
__wine_dbg_get_channel_flags 8,765, __wine_dbg_strdup 8,762, __wine_call_gcc_ctors 7,439,
__wine_call_gcc_dtors 7,439, wine_dbg_sprintf 6,382, wine_dbg_vprintf 6,331,
fallback__wine_dbg_get_channel_flags, fallback__wine_dbg_header, fallback__wine_dbg_output
and fallback__wine_dbg_strdup 6,167 each, winecx 6,121, wine_dbgstr_wn 4,716,
__wine_spec_unimplemented_stub 3,824, _wine_dbg_log 3,254, wine_dbgstr_an 2,692. By part:
Wine's Windows half 316,716 (1,579 files), Gecko 9,600, wine-mono 3,799, Wine's Mac half
2,070, DXVK 54, DXMT 78. Of 1,219 tokens that looked not-Wine, 930 were read as such and
allowlisted (`not-wine`: 811 LLVM `Twine` symbols in DXMT, 91 Windows `WinE…` names, 28
words) and 289 refer to Wine. For Plan 3c: `winecx` is the source folder, baked into 1,033
files through `__FILE__`, so the renamed tree is built in a folder without "wine".

## Plan 3c-1: the engine without wine

Engine 5.0.0 (`build-engine.sh`, `version` 5.0.0) is Wine 11.19 + CrossOver (the tree Plan 3b
reproduced) renamed by `scripts/anowine/rename_sources.py` after the patches and before
configure, built in `$RUNNER_TEMP/ano-engine/ano-src` with prefix `/opt/ano`, laid out as
`Libraries/Ano` (`bin/ano-loader` → `lib/ano/x86_64-unix/ano-core`, `bin/ano-server`,
`lib/ano`, `share/ano` with an LGPL `NOTICES`) and `Libraries/AnoRuntimeVersion.plist`.
DXVK, DXMT and wine-mono are not in it yet (Plan 3c-2); Gecko is dropped.

**The rename** of the pinned tree: 183 paths, 4,917 text files, 34 binary files listed (30
fonts, ICU data, pidgen's `bink.bin`, two test scripts). Rules: 16 protected entries (10
Windows names such as `winerror` matched anywhere, 3 English words, 3 license phrases), 20
map entries (13 programs `ano-…`, 4 reverse-DNS identities, 2 URL rules to the repo, 1
misspelling). Fonts and `bink.bin` are renamed in place by `rename_binaries.py` (fontTools
4.57.0); MoltenVK's copy of the SPIR-V tool table ("Wine VKD3D Shader Compiler") is renamed
in place too. Things the plain text rule missed, each found by a build: a program name used
as a C identifier (`WINE_DECLARE_DEBUG_CHANNEL(winedbg)` must become `anodbg`, not
`ano-dbg`); strings Wine spells as character arrays (`{'w','i','n','e','b','o','o','t',…}`:
48, among them the boot program ntdll starts); two translations that write "WIne".

**The gate** (`wine_tokens.py --gate` over the engine and a new bottle): before the rename
41,653 distinct tokens (Plan 3b); after it 123 distinct tokens (726 occurrences), every one renamed or allowlisted (build
run 44649189634, gate green). The allowlist has 979 entries: 967
`not-wine` (Windows and LLVM names, English words, ICU's Unicode names such as "B131 WINE"
as phrases so a bare WINE still fails), 8 `alias`, 3 `license`, 1 `code-only` (the repo URL).

**Aliases** (`scripts/anowine/aliases.txt`, `patches/rename/0002-ano-aliases.patch`), all
provisional until the owner's `ano-gptk-wine-names.txt`: the "Wine builtin DLL" mark is
accepted beside Ano's (ntdll's loader, the server, setupapi), ntdll.dll exports
`__wine_unix_call` (CrossOver's own note: "Needed by D3DMetal PE DLLs"),
`__wine_unix_call_dispatcher` and four `__wine_dbg_*` names, and ntdll.so falls back to
`__wine_unix_call_funcs` and its wow64 table. `check-aliases.sh` proves it with a stand-in
for D3DMetal (a DLL with the old mark and imports, a Mac half with the old table):
`alias_call(21) = 42`. The mark is read through a volatile pointer, or the compiler folds
it into instructions (`xor eax,'Wine'`) where the gate cannot tell it from a real "Wine".

**Shorter names**: wine -> ano makes a string one letter shorter, and Wine spells some
lengths as numbers (`wcsncmp(p, L"WINEDEBUG=", 10)`, then a `memmove` 10 past it).
`patches/rename/0003-ano-lengths.patch` fixes the 11 such sites, the minidump marker and
the font vendor compares; `check_lengths.py` runs after the patches and stops the build on
a new one. `rename_sources.py` also stops on `anohq` (a domain Ano does not own) in
anything that ships, matches URLs in any case, and joins gettext's wrapped strings so a
URL split over two lines is one URL. Found by the final review (Opus).

**Build**: 1,914 s on a warm compiler cache (build 44674369437, every check green); make 740 s in build 3. Plan 3b's 4.8.3 still reproduces
(re-run 44643236968: 0 different, 0 unexplained interface).

**For Plan 3c-2 and later**: the bottle is booted with `mscoree` and `mshtml` disabled until
mono is renamed and Gecko's download dialog is gone; DXVK, DXMT and wine-mono come back
rebuilt or renamed. On CI the bottle log warns that `anobth.sys` cannot start (no
Bluetooth) and that `cxcompatdb.so` is missing; both to be compared with upstream's 4.8.3.
Risk carried: programs that look for Wine (`wine_get_version`, `Software\Wine`) no longer
find it.
