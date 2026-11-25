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

## Plan 3c-2: DXVK, DXMT and mono

Engine 5.0.0 now carries DXVK and DXMT rebuilt from source and wine-mono renamed in place;
Gecko is not shipped and nothing offers to download it. Run 44823000994: the gate passes over the engine (977
distinct tokens) and over a bottle made the way the app makes one, with no DLL overrides (92),
all renamed or allowlisted; every check below is green.

**DXVK** is built on Linux (job `Payloads (Linux)`, `scripts/anowine/build-payloads.sh`,
about 8 minutes with the package cache): Gcenx's DXVK-macOS `8f1e28de` (the
v1.10.3-20230507 async repack: d3d10core and d3d11, 64- and 32-bit) and upstream DXVK
v1.10.3 `e4fd5e9e` for the 32-bit dxgi only (d3d9 and d3d10 off), with mingw's posix thread
model (winpthreads) as DXVK's releases use. Both trees are renamed with
the engine's map before meson (`winevulkan.dll` becomes `anovulkan.dll`, and so on). Ubuntu's
GCC 13 needed `<cstdint>` in two headers of upstream 1.10.3 (`patches/dxvk/`), the same two
lines Gcenx's branch carries.

**DXMT** v0.80 `589adb78` (with its nvapi and directx-headers submodules at their pins) is
built on the Mac against the renamed engine's own build tree, with meson 1.10.0 and LLVM
15.0.7 `8dfdcc7b` built as DXMT's CI does (cold about 25 minutes, then cached by its commit:
the DXMT phase takes 5 minutes). Homebrew's GCC 16 needed `<iomanip>` in one file
(`patches/dxmt/`). Its bridge is `anometal.dll` and `anometal.so` (linked to `anomac.so`); its
front ends go to `Libraries/DXMT` with the plain DOS stub, as in 4.9.0, and the bridge goes there
too, because the app copies the front ends and the bridge from that folder into a bottle.

**Graphics in a bottle** (`check-graphics.sh`, every DLL loaded by path as itself, then a
D3D11 device created; runner GPU: Apple Paravirtual device):

| | 64-bit | 32-bit |
|---|---|---|
| DXVK | loads; device created (S_OK) | loads; device creation crashes in Vulkan |
| DXMT | loads; device created (S_OK) | loads; device created (S_OK) |

The 32-bit DXVK crash is the runner's: the prebuilt DXVK that 4.9.0 ships crashes the same way
in the same bottle (an A/B step in the check job). DXMT's nvapi64 and nvngx keep DXMT's
builtin mark, as in 4.9.0, and the app never deploys them.

**wine-mono** 11.3.0 cannot be rebuilt, so it is renamed in place (`rename_binaries.py
--tree`): the folder `ano-mono-11.3.0`, 238 PE files with every length kept (a path part
repeats its separator, `wine-mono/` → `ano-mono//`; a NUL-terminated string is padded;
renamed export tables are sorted again, since Wine finds exports by binary search), and the
support installer rebuilt as a new MSI (msitools) with the feature `ano_mono`, product
"Ano Mono Windows Support", manufacturer "The Ano Project", cabinet `anomono-support.cab`
(its two `installutil.exe` renamed, their hashes recomputed). Its internal assembly names
(`WineMono.*`) stay, as decision 7 says. A .NET program compiled against the engine's own
mscorlib runs in the bottle, and the support install leaves its files (from the renamed
cabinet), the `AnoFakeDlls` fakes and "Ano Mono Windows Support" in the registry.

**Gecko**: `patches/rename/0004` makes `appwiz.cpl` install an addon only from the engine, a
registered folder or the cache; asking for Gecko as mshtml does returns at once (before:
a download dialog that waited). A bottle with no DLL overrides boots without a dialog.

**Allowlist**: 995 entries: not-wine 981, alias 9, license 3, code-only 1, mono-internal 1
(`WineMono`). Added here: 13 Windows names wine-mono carries (`WinEvent` fields,
`WINEVENT_*`, `winexe`, `winerror`) and LLVM's `winehprepare`.

**Open**: DXVK and DXMT are rebuilt with newer compilers than the originals (GCC 13 and 16):
on the runner they behave as the prebuilt ones, but only a game on the owner's Mac proves
them. The app (3c-4) still asks for DXMT's bridge as `winemetal.dll`; the payload now holds it as
`anometal.dll`. The final review (Opus) found the missing bridge, the ungated default bottle and
the thread model; all three are fixed.

## Plan 3c-3: ano-tricks

`Libraries/ano-tricks` is winetricks 20260125 (upstream `src/winetricks` at that tag, SHA-256
`431f82fc…`) made by `scripts/anowine/make_ano_tricks.py`; Hygiene makes it again from the
pinned file and fails if the committed one differs. 18,868 lines; the gate over the file passes
(its only tokens: AutoHotkey's `IfWinExist` in verb scripts, allowlisted as not-wine, and the
`winevent` API set).

**Renamed** by the engine's rule and map, which gains `winetricks` → `ano-tricks`, `Winetricks`
→ `Ano-tricks` and `github.com/Winetricks/winetricks` → the repo URL: `ANO`, `ANOSERVER`,
`ANOPREFIX`, `ANODLLOVERRIDES`, `ANOTRICKS_*`, `Software\Ano\DllOverrides`, `ano-boot`,
`ano-tricks.log`, `ano-11.19` version parsing; Wine bug links point to the repo's issues.

**Dropped verbs**, all of which download from other people's paths named after Wine (renamed,
those paths would not exist, or would be someone else's to claim); the app uses none:
`galliumnine*` (Gallium Nine needs Mesa, which a Mac does not have), `ie7`, `ie8`,
`ie8_kb2936068`, `ie8_tls12`, `otvdm`, `otvdm090` (16-bit Windows programs), and `powershell`
(the wrapper; `powershell_core`, PowerShell itself, stays). The generator stops if any Wine URL
is left that the map does not replace.

**Edits**: the update check, self-update, stats report and the download-failure hint are
stubs. The hint looked up the user's country at ipinfo.io (their IP address, outside the
proxy) whenever a first download failed or a checksum differed, as vcrun2019's does today
because Microsoft serves a newer file. Upstream checks
raw.githubusercontent.com on every run, outside the bottle's proxy, and once renamed, its
self-update would fetch from a GitHub account (`Anotricks`) anyone could register. The cache
is `~/Library/Caches/io.github.highstormpvp.Ano/ano-tricks`; upstream's was `~/.cache/winetricks`,
because it sets `XDG_CACHE_HOME` before its macOS default applies. Three comment links to other
sites' pages about Wine are removed. When the loader's architecture cannot be read (a wrapper
script first on PATH, as the proxy has, or `lipo` on a Mac without Xcode's tools), upstream
guesses the 64-bit loader as `wine64`; renamed, that turned `ano-loader` into `ano64-loader`,
and every verb failed. ano-tricks keeps the loader's name (the engine has one loader). The top
of the file says it is a modified copy of Winetricks 20260125, changed on 2026-11-21, as LGPL
2.1 §2(b) asks; the phrase is on the allowlist as a license line.

**A bug fixed on the way**: upstream's vcrun2022 (master too) copies `msvcp140.dll` out of
the redistributables' cabinets itself, because their installer keeps the builtin, which has a
higher version number. But the pinned 2022 cabinets name the file `msvcp140.dll_x86` and
`msvcp140.dll_amd64`, so nothing was extracted and the verb still exited 0: games got Wine's
builtin `msvcp140`, in today's app too. ano-tricks takes any `msvcp140.dll*` from the cabinet
(`w_ano_msvcp140`), and if a later redistributable has none, it keeps the builtin with a
warning, as upstream did, instead of failing the app's main verb. vcrun2019's cabinets say
`msvcp140.dll` and work.

**In a bottle** (`check-ano-tricks.sh`, engine 5.0.0's default bottle, called as the app calls
it: one verb per call, `--force` for vcrun, the app's environment only; run 44862494158):

| verb | result | time on the runner |
|---|---|---|
| vcrun2022 | `msvcp140` and `vcruntime140` native, 64- and 32-bit | 152 s |
| d3dcompiler_47 | native, override under `Software\Ano` | 85 s |
| d3dx9 | `d3dx9_43` native, override | 111 s |
| xact | `xactengine3_7` (32-bit) native | 459 s |
| xinput | `xinput1_3` native, override | 131 s |
| remove_mono (dotnet48's first step) | finds "Ano Mono Windows Support" and removes it | 152 s |

Each verb is in the bottle's `ano-tricks.log`; there is no `winetricks.log` and no
`Software\Wine` key. The downloads (142 MB) sit in Ano's cache folder and nothing goes under
`~/.cache`. With a wrapper `ano-loader` first on PATH and no `ANO_BIN`, `list-installed` still
works. The bottle passes the gate.

**For 3c-4 (the app)**: call `Libraries/ano-tricks` with `ANO`, `ANOSERVER`, `ANOPREFIX`
(`Winetricks+Install.swift`, `Winetricks+InstalledVerbs.swift`, the Terminal script in
`Winetricks.swift`), and for a proxied bottle `ANO_BIN` where it passes `WINE_BIN` today
(`ProxyEnvironment.swift`); read `ano-tricks.log` (`Winetricks+InstalledVerbs.swift`); make
`Libraries/verbs.txt` again from `ano-tricks list-all` (today it is upstream's list: the dropped
verbs and 82 "wine"s); then drop `Libraries/winetricks`.

## Plan 3c-4a: the app on engine 5.x

The app now speaks only the renamed engine's names (runtime 5.0.0); on `main` it needs that
runtime, which 3c-5 publishes. Plan `docs/superpowers/plans/2026-11-21-ano-plan3c4a-app-runtime.md`.

**What the app expects of the runtime**: `Libraries/Ano` (`bin/ano-loader`, `bin/ano-server`,
`lib/ano`, `share/ano`) beside `Libraries/AnoRuntimeVersion.plist` (same keys); a `Libraries/Wine`
runtime reads as not installed, so Setup offers the new one. The feed is
`AnoRuntimeVersion.plist` (written with the release in 3c-5). Every variable is `ANO*`
(`ANOPREFIX`, `ANODLLOVERRIDES`, `ANOD3DMETAL`, `ANOESYNC`, …), the registry is `Software\Ano`,
bottle creation runs `ano-cfg`, DXMT's bridge is `anometal.dll`, the version parse reads `ano-`,
crash patterns match `ano:` lines, the Terminal gets `ano-*` aliases (none named `ano`, which is
the CLI). The app runs `ano-tricks` with `ANO`, `ANOSERVER`, `ANOPREFIX` (and `ANO_BIN` for a
proxied bottle) and reads `ano-tricks.log`; `Libraries/verbs.txt` is `ano-tricks list-all` (no
"wine" left). The proxy's variable is `ANO_RUNTIME_DIR`. `check_app_runtime_names.py` (Hygiene)
finds every such name in the app's literals and bundled JSON: 194 at the start, 0 now; three
lines keep an old name on purpose (the mark Apple's D3DMetal DLLs carry, the old-bottle check).

**D3DMetal's variables** (owner's ruling): Apple's D3DMetal reads `WINED3DMETAL` and `WINEESYNC`
itself. The app sets `ANOD3DMETAL` and `ANOESYNC`; `patches/rename/0005` makes each engine
process copy them to the old names in its own environment after its Windows environment is
built, and drop them from every environment it hands on (CrossOver's hand-off to a new process,
the server spawn, a forked child before exec). `check-env-aliases.sh` (engine run 44912708138,
checks 44922096835): the Mac half of a D3DMetal stand-in reads both as `1`; the Windows
environment has neither; `ps -E` shows neither on the program, its child or the server.
Provisional until the owner's `ano-gptk-wine-names.txt` confirms which names D3DMetal reads.

**Old bottles** (decision 3): a bottle whose `system.reg` starts `WINE REGISTRY` or whose
`Metadata.plist` has a key with "wine" is recognised before its settings are decoded, listed as
"Made with an earlier Ano", refused for every run and setting, and never written; removing it
still works. New bottles' files have no "wine" keys.

**End to end** (`check-app-on-engine.sh`, engine check 44949053420): the `ano` CLI, built from
this tree, with engine 5.x where the app keeps its runtime, creates a bottle and runs a program
in it (it writes its file and exits 0); the bottle starts `ANO REGISTRY`, the app's keys are under
`Software\Ano`, `ano shellenv` sets only `ANO*`, and the gate passes over the bottle. A bottle
from Ano 8, on the list as an update leaves it, is listed, refused with the message, and stays
byte for byte as it was. `Ano Proxy` passes on engine 5.x and still on runtime 4.9.0.

**Left**: 3c-4b (what users see: UI text in every language, logs, CLI text, `Info.plist`, the
`wineglass` symbol, troubleshooting text, GameDB keys and text, the full source check), 3c-4c
(first launch: old traces, the admin script, moving an imported GPTK store from `lib/wine` to
`lib/ano`, the update-check opt-out), 3c-5 (the release). On the owner's Mac: D3DMetal with the
alias, once the listing confirms the names.

## Plan 3c-4b: what users see

Nothing the app shows, logs or bundles says "wine" any more. Plan
`docs/superpowers/plans/2026-11-22-ano-plan3c4b-app-text.md`.

**The check**: `check_app_text.py` (Hygiene) reads every Swift string literal of the app's
targets (interpolations are code and left out), every key and value in every language of
`Localizable.xcstrings`, the JSON WhiskyKit bundles, the `Info.plist` files and `verbs.txt`.
1,993 places at the start (1,322 in the catalog, 340 in GameDB), 0 now (Hygiene 45121213544).
The repo's own URL (`github.com` and `raw.githubusercontent.com` `/HighStormPVP/AnoWine`) is the
only text it lets through; github.io never. `check_catalog_keys.py` (Hygiene) fails when a key the
Swift sources name is missing from the catalog, so a key renamed on one side only can't show as a
raw key; two partial renames were caught in mutation runs. `BundledDataNamesTests` pins GameDB
(87 entries, 90 variants; `minAnoVersion` 85, `anoTricksVerbs` 90, `anoVersion` 89, read and
decoded), the remediations' `anoTricksVerb` and the renamed ids, so no entry drops silently.

**What changed**:
- **Catalog:** `rename_app_text.py --keys --values`. It renamed 116 keys together with their Swift uses, and changed 1,206 values across 24 languages.
- **Rewordings:** 160 values, listed in the script's `REWORDINGS` and `RUNTIME_WORDING`.
  - Grammar: French elision, Czech, Finnish, Turkish and Korean endings.
  - Where a translation said plain "Wine" for the runtime, it now uses its own word for the runtime ("Ano-Runtime", "runtime Ano", "Ano ランタイム"). A plain "Ano" there would name the app.
- **Swift text:** log categories (`AnoKit`, `Ano`, `AnoRuntimeInstaller`, `AnoTricks`, …), log and diagnostics text, the CLI's help, and `Info.plist`'s permission text.
- **Exports:** the files are now `ano.log` and `ano.tail.log`, and the key is `anoRuntimeVersion`.
- **Symbol:** `wineglass` became `flask`.
- **CLI flag:** `ano uninstall --runtime`/`-r` (was `--whisky-wine`/`-w`).
- **GameDB:** the keys are `anoTricksVerbs`, `anoVersion` and `minAnoVersion` (`CodingKeys`; the Swift properties keep their names). 55 notes were reworded.
- **Remediations:** the key is `anoTricksVerb`.
- **Ids:**
  - fix `install-ano-tricks-verb`
  - check `anoTricks.verb_check`
  - flow nodes `check_ano_tricks`, `check_ano_dns`, `fix_ano_dns`
  - pattern `ano-nonzero-exit`
  - variants `recommended-anod3d`, `anod3d-winxp`

  None is migrated: only bottles made on engine 5.x (unpublished) can hold them.
- **Removed:** Sparkle's github.io feed URL (`SUFeedURL`, `DistributionConfig.baseURL`/`appcastURL`). Sparkle stays off without `SUPublicEDKey`.

**How text about Wine was reworded** (so it stays true):

| Was | Now |
|---|---|
| Wine version (the engine's) | engine version ("Ano version" reads as the app's) |
| Wine's own Direct3D / d3d11, the Wine builtin marker | the engine's own …, the engine's builtin marker |
| Wine PID, Wine username (logs) | Windows PID (the one `taskkill` takes), Windows username; the UI still says "Ano PID" and "Ano processes" (3c-4c) |
| "like Wine" as Rosetta's example of x86 code | "like Ano's engine", in every language (plain "Ano" would call the native app x86 code) |
| WhiskyWine (the runtime), WineD3D, winetricks | Ano runtime, AnoD3D, ano-tricks |
| "BattlEye / EAC Wine/Proton support" | "BattlEye's / EAC's Proton support" (the vendors' opt-in) |
| "does not work under Wine", "the Wine prefix AppData" | "does not work in Ano", "the bottle's AppData" |
| "WineHQ bugs 56463 and 58543", "upstream Wine HDRP support" | "upstream bugs …", "the engine's HDRP support upstream" |
| GameDB tags "Wine 9.0+", "Tested with Wine 9.0" | "Engine 9.0+", "Tested with engine 9.0" |

**Kept on purpose**:
- Code-only names (decision 6): Swift identifiers, type and file names (`WhiskyWineInstaller`, `Wine.swift`, `winetricksVerbs` properties). Comments, tests and `Documentation.docc` also keep them.
- `// old name:` lines:
  - the D3DMetal DLL mark;
  - the old-bottle check;
  - the update-check opt-out's defaults key `checkWhiskyWineUpdates`. Renaming it would switch the check back on for anyone who turned it off, so 3c-4c migrates it.
- The repo URL.

**Left for 3c-4c**:
- Text that still says Whisky (not wine):
  - the CLI's `run` help ("whisky run MyBottle");
  - diagnostics' "Whisky Version:";
  - one log subsystem;
  - the catalog's "original Ano" where it means Whisky.
- First-launch cleanup.

## Plan 3c-4c: first launch

The first launch of the renamed app removes what Ano 6–8 left with "wine" in its name, carries
the user's settings and imported Game Porting Toolkit across the rename, and stops offering an
import that could only list refused bottles. Plan
`docs/superpowers/plans/2026-11-23-ano-plan3c4c-first-launch.md`. CI 45225165123 and Hygiene
45219538083 are green on the last task; `check_app_text.py`, `check_app_runtime_names.py` and
`check_catalog_keys.py` print 0.

**Launch order** (read from the call sites, not yet watched on a Mac):
1. `WhiskyApp.init` starts Sparkle and the telemetry consent check (neither reads a migrated key).
2. `applicationWillFinishLaunching` runs `AppMigrations.runAtLaunch()`, synchronously.
3. When the window shows, the runtime update check reads `checkAnoRuntimeUpdates` and the GPTK steps
   (`verifyStoredPayload`, `deployStoredPayloadIfMissing`, the `ensure…` calls) start.
4. `applicationDidFinishLaunching` starts `OldTraceCleanup.runIfNeeded()` in the background (not
   under UI tests). It runs once: defaults key `oldTracesCleanupVersion` = 1, written even when a
   removal failed (logged under `AnoMigration` and skipped). It cleans only on a Mac that had Ano
   6–8's runtime (`Libraries/Wine`, which every trace below needs); a fresh install is marked done
   and cleans nothing.

**What the cleanup removes** (inventory from tags `ano-test-6/7/8`, the bundled winetricks and three
trace scans):

| Trace | Rule |
|---|---|
| `~/.cache/winetricks` | removed, unless Homebrew or MacPorts winetricks or the original Whisky (`com.isaacmarovitz.Whisky`, `com.franke.Whisky` in Application Support) is on the Mac: every winetricks shares this cache. A symlink there loses only the link |
| `/tmp/.wine-<uid>/server-*` | removed only when its `lock` is not held (`fcntl` `F_GETLK`), so a live server, Ano's or another Wine app's, stays; `.wine-<uid>` itself goes by `rmdir` once empty, and only a real folder owned by the user is looked into |
| `org.winehq.wine` (runtime 3.1.x) and `com.codeweavers.CrossOver.wineloader` (runtime 4.9.0) | Metal shader caches in the user cache folder and `~/Library/Caches`; removed. If CrossOver is installed it shares the second id and rebuilds its shader cache once |
| `$TMPDIR/winetricks.*` folders, `whisky-winetricks-*.sh` | removed (a crash or force-quit leaves them) |
| `$TMPDIR/whisky-run-*.sh`, `whisky-env-*.sh`, `whisky-registry-*.reg`, `whisky-dll-overrides-*.reg` | removed only when their text says "wine" (UTF-8 or UTF-16): the current app still writes these names with Ano text |
| `Proxy/bin/ano-loader` | removed when its text says "wine" (Ano 6–8's wrapper); the proxy writes the current one when a proxied bottle needs it |

The app never asks for admin rights and deletes only in the home folder, the temporary folder, the
user cache folder and `/tmp/.wine-<uid>`. Files checked by their text are read only when they are
regular files. Temporary items younger than a day stay (`temporaryItemMinimumAge`, by the item's own
modification time), so a live winetricks run of another app keeps its working folder.

The final review (no Critical) found the shared winetricks cache (Important) and the live temporary
folder; both are fixed (CI 45289465182, Hygiene 45289470172).

**Kept on purpose**:
- bottles, whole (decision 3);
- `Libraries/Wine`, which the runtime swap replaces;
- Ano 6–8 logs (the user's diagnostics; their text holds Wine output, and log retention prunes them);
- the user's saved diagnostics and app shortcuts;
- `/usr/local/bin/ano` (a clean name; removing it needs admin rights).

winemenubuilder's XDG files are never written on macOS. Runtime 5.x's server folder is
`/tmp/.ano-<uid>` by the rename rule; no runner has shown it yet.

**Migrations** (`AppMigrations`):
- Defaults:
  - `checkWhiskyWineUpdates` → `checkAnoRuntimeUpdates`, so an update-check opt-out survives;
  - `wineSectionExpanded` → `anoSectionExpanded`.

  The old value is copied only when the new key is absent. `hasOfferedLegacyMigration` is dropped,
  and any other key containing "wine" is swept on every launch; the current app writes none.
- GPTK store: Ano 8's `lib/wine` becomes `lib/ano` (`adoptModuleFolder`; `lib/ano` wins when both
  exist). A store that was verified is stamped again, so D3DMetal keeps working without a new
  import. A store that wasn't verified stays unverified. Originals backed up from a runtime below 5
  are dropped. A test deploys the migrated store into a fake runtime.

**Import removed**: the original-Whisky import sheet, its first-launch offer, the File-menu command,
`LegacyBottleImport` and 7 catalog keys are gone. Every bottle it found was an old bottle the app
refuses. The UI test `testTheFileMenuHasNoWhiskyImport` checks the menu. The README's upstream part
still describes the command.

**Wording**:
- PIDs and the kill-on-quit setting:
  - "Ano PID" is now "Windows PID" (key `process.detail.windowsPID`).
  - The kill-on-quit setting says "Terminate Windows programs when Ano closes".
  - Both changed in all 24 languages.
- GameDB:
  - Five anti-cheat workaround/"until" lines no longer cite the vendors' Proton support, which is Linux-only. They now name support for macOS or for compatibility layers on macOS.
  - Its "Whisky picks / Whisky's DXVK / Whisky's Library" notes say Ano.
  - "Whisky Community" (the author), `referenceURL` links and `frankea/Whisky#N` stay.
- CLI: `ano run` help, "is not an Ano bottle", and the usage line says `ano`, because ArgumentParser named the command after its Swift type, so `commandName: "ano"`.
- Diagnostics: "Ano version:" and the exported report titles say Ano. The audio probe logs under the app's bundle id.
- Checks:
  - `check_catalog_keys.py` now checks keys passed as `label:`.
  - `test_app_wording.py` (Hygiene) and `BundledDataNamesTests` (no Proton in workarounds, no "Whisky" outside `author`) pin the new text.

**Admin script**: `scripts/anowine/clean-rosetta-cache.sh` lists, and with `--delete` removes, Rosetta's
cached translations of old runtime files (`/var/db/oah/.../*wine*.aot`, regular files only). The
owner runs it once with `sudo` (`TESTING-ON-M2.md`, "Ano 9: clean old traces"). It reports what it
could not remove (exit 1). Whether SIP lets root delete there, and the script on BSD find and bash
3.2, are untested until that run. 3c-5 attaches it to the ano-test release.

**Not checked on a Mac yet**:
- that `applicationWillFinishLaunching` runs before the window's update check. If not, the first
  launch could ignore the opt-out once and deploy D3DMetal one launch late;
- what a GUI game leaves (Saved Application State, a preferences domain): the scans ran console
  programs only.

**Left** (not "wine", outside this plan's named items):
- "No Ano processes running for this bottle" and "This is an Ano system process" (same misreading as the PID label);
- the bottle-creation failure report's title "Whisky Bottle Creation Diagnostics" (`BottleVM.swift`);
- `com.franke.Whisky` / `com.isaacmarovitz.WhiskyKit` log subsystems;
- the export names `whisky-diagnostics-*.txt` / `Whisky-Diagnostics-*.zip`;
- the README's upstream text.

A full "Whisky" sweep is a separate follow-up.

## Plan 3c-5: the gate and the release

The rename now has a gate in CI on every engine build and every app build, including what a session
leaves on the Mac. Runtime 5.0.0 is published, and Ano 9 is out for testing. Plan
`docs/superpowers/plans/2026-11-24-ano-plan3c5-gate-release.md`; the ledger is in
`.superpowers/sdd/2026-11-24-ano-plan3c5-gate-release/`.

**Where the gate runs:**

| Build | Job | What it judges |
|---|---|---|
| `Ano Engine` 5.x | `Renamed source (Linux)` | the renamed source: the rename patches apply, `check_lengths`, and the spawn-site scan |
| `Ano Engine` 5.x | `check` | the engine and a new bottle (`wine_tokens.py --gate`), the license texts (`check-licenses.sh`), the alias helpers' links, and the older checks |
| `Ano Engine` 5.x | `gate` | the Mac-state gate (`scan-wine-traces.sh`) and its planted self-test, plus the upstream boot-warning report |
| `AnoWine Test Build` | `gate` | the app bundle, judged by its Mach-O facts (`macho_facts.sh`, `wine_tokens.py --skip-macho`); then the app's Mac-state gate (`--app`), on the published runtime from the feed or on `engine_run` |

`AnoWineTraceScan.yml`, the report-only 4.x scan, is gone.

**What the Mac-state gate captures.** The session boots a bottle, runs `cmd /c set`, opens
`ano-cfg`, `regedit` and `notepad`, and runs the `win10` verb, under a persistent `ano-server`. With
`--app`, it also runs `ano create` / `ano run` and opens the app for 60 s. Only what is new since
the start is captured:
- the processes' command lines, environments and open files;
- the Windows environment;
- files created or changed under HOME, the temporary folder, the cache folder and `/private/tmp`;
- new defaults domains, `launchctl` and `lsappinfo` lines, and LaunchServices;
- new files in Rosetta's cache;
- the system log.

Three things are left out of the file capture:
- the runner's own folders;
- files dated after the session's end (bazel dates its files years ahead);
- other apps' sandbox containers, except Ano's own (macOS lets only the owning app write there).

The session gets only the environment the app gives the engine, and harness processes are told apart
by PID, not text.

The planted run (`PLANTWINE` in a program's environment, `~/.cache/plantwine/x`, a `plantwine` log
line) must fail with exactly those tokens, each found by its own capture. Otherwise the gate counts
as blind and exits 2. On the release candidate both runs pass: 92 tokens, all allowlisted, all
inside the bottle.

The one new `not-wine` entry is `intertwined`, written into helpd's cache by Apple's Help daemon.
Apple's daemons write 80–550 files into HOME per session. If one ever says "Wine", no category fits
and the owner must rule.

**Spawn sites** (`spawn_sites.py`, list `spawn-sites.txt`). There are 12 sites:
- 10 drop the D3DMetal aliases before they start a program;
  - 5 already did through patch 0005: three calls in ntdll's loader (`build_path_and_exec`,
    `preloader_exec`), `__ano_unix_spawnvp` and `fork_and_exec`;
  - 5 do through the new patch 0006: localspl's print command and its two `posix_spawn` calls,
    msv1_0's `ntlm_auth`, and netapi32's `smbpasswd`, a fifth leak the plan had not listed;
- 2 are not spawns: msvcrt's own `system()` and wininet's call to it.

Patch 0006 exports the helpers from ntdll.so the way `ntdll_umbstowcs` is exported. A new site, an
unhandled one, or a listed one that disappears stops the build. In this build only localspl's
print command and msv1_0's `ntlm_auth` are compiled in: CUPS is off, and there is no samba.

**Licenses** (`licenses.txt`, `collect_licenses.py`, `check-licenses.sh`). There are 146 components
and 241 license texts, covering 5,608 files; the first component whose globs match a file wins.
- The texts are the components' own, taken from their sources at the pinned commits.
- Each nixpkgs line must match nixpkgs at `NIXPKGS_REV` in version and SPDX id.
- `NOTICES` has a table: component, version, license, source, and what Ano changed.
- New allowlist entries (`license`) are 7 phrases from texts shipped word for word: Wine's AUTHORS,
  LICENSE and NOTICES.md, mpg123's AUTHORS, and wine-mono's COPYING.
- `NOASSERTION` appears for the GPTK shims, whose upstream publishes no license; the owner ruled to
  ship them as they are. It also appears for six xorg libraries that nixpkgs gives no license; their
  COPYING files still ship.

**Boot warnings.** Upstream's v4.8.3 shows both of the warnings 5.x shows: the Bluetooth driver
fails (`c00000e5`; `winebth` there, `anobth` here), and `error loading cxcompatdb.so` appears once
per process start. Both are inherited, not caused by the rename.

**The release:**
- **Runtime v5.0.0**, "Latest", published by `Ano Engine`'s new `publish` job (run 45483468315).
  It is the release candidate from build 45326779119, checked again in the same run. The job
  refuses notes that don't name the engine's SHA-256, and an engine whose plist names another
  version. Asset SHA-256 `6e247eca…987b`.
- **Feed.** `dist/pages/AnoRuntimeVersion.plist` (read by Ano 9 and later), checked by `Ano Feeds`
  (45502260850): all three feeds have their digest OK.
- **Proxy.** `Ano Proxy` runs on v5.0.0 (45502403194), and a 4.x layout is refused.
- **Ano 9.** `ano-test-9` (pre-release, commit 4244bb83): `Ano-9.zip`, `clean-rosetta-cache.sh` and
  `list-gptk-wine-names.sh`. Test build 45502814878: build and app gate green on the published
  runtime. Owner test items: `TESTING-ON-M2.md` "Ano 9: runtime 5.0.0".

**Owner's rulings at the release (2026-11-25):**
- Publish 5.0.0.
- Let Ano 9's D3DMetal game test decide the aliases instead of the listing. The aliases stay
  provisional; a failure is fixed in 5.0.1.
- Ship the GPTK shims as they are.
- Add a source download for the GPL codecs later.

**Left:**
- A source download for the runtime's GPL parts: gst-plugins-bad, x264, x265 and the like.
- Code built into components without its own text shipped: MoltenVK's SPIRV and cereal, DXMT's
  nvapi headers, the mingw runtime.
- `libano_net.dylib` has no install name, so the build path is its id.
- `bundle_libraries` copies the GStreamer plugins twice (about 60 MB).
- The children that clear the aliases after `fork` (cups.c, netapi32, and 0005's) call `unsetenv`
  in a multi-threaded process.
- The "Whisky" sweep.
- The Opera GX test, queued by the owner.
