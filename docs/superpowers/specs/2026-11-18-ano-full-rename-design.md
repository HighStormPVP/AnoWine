# Ano without "wine": full rename — design

Date: 2026-11-18. Status: approved by the owner on 2026-11-18. Plan 3a:
`docs/superpowers/plans/2026-11-18-ano-plan3a-upstream-engine.md`.
Inputs: the five-agent audit and the trace scans of 2026-11-18 (workflow `AnoWine Trace Scan`,
runs 44173510221 and 44188982344; script `scripts/anowine/scan-wine-traces.sh`). The appendix
condenses what they found.

## Intent

The owner wants nothing that Ano ships, runs or creates to carry the word "wine" in any case:
not in names, not in file contents, not on the Mac, not inside bottles. In their words: "rename
all that to Ano, remove all wine". This continues the renames already shipped (`ano-loader`,
`ano-server`, `ano-core`, `ano-boot.exe`, `ano-device.exe`, runtimes v3.1.3 to v3.1.6).

## Decisions the owner made (2026-11-18)

1. **Scope: everything.** The Mac side (Finder, `ps` and Activity Monitor, Dock, Terminal, logs,
   caches, `/tmp`, system registrations, the app's UI) and the inside of bottles (file names,
   file contents, registry, environment, the names Windows programs can see).
2. **Naming rule.** Programs that run as processes get `ano-` plus the rest of the old name;
   everything else swaps `wine` → `ano`, `Wine` → `Ano`, `WINE` → `ANO`. Examples:
   - programs: `winecfg.exe` → `ano-cfg.exe`, `winebrowser.exe` → `ano-browser.exe`,
     `winedbg.exe` → `ano-dbg.exe`, `wineconsole.exe` → `ano-console.exe`,
     `winemenubuilder.exe` → `ano-menubuilder.exe`, `winepath.exe` → `ano-path.exe`,
     `winefile.exe` → `ano-file.exe`, `winemine.exe` → `ano-mine.exe`,
     `winemsibuilder.exe` → `ano-msibuilder.exe`, `winevdm.exe` → `ano-vdm.exe`,
     the `winetricks` script → `ano-tricks`;
   - everything else: `winemac.drv` → `anomac.drv`, `winebus.sys` → `anobus.sys`,
     `wined3d.dll` → `anod3d.dll`, `Software\Wine` → `Software\Ano`, `WINEPREFIX` → `ANOPREFIX`,
     `/tmp/.wine-<uid>` → `/tmp/.ano-<uid>`, `lib/wine` → `lib/ano`, `share/wine` → `share/ano`,
     `Wine builtin DLL` → `Ano builtin DLL`, `WINE REGISTRY` → `ANO REGISTRY`,
     `wine_get_version` → `ano_get_version`, `WINEBUS\...` device IDs → `ANOBUS\...`.
3. **Old bottles are not converted.** Bottles made with a runtime before this rename stop working
   with the new runtime; the owner recreates them (and reinstalls Steam and games).
4. **Closed parts get hidden aliases.** Where a part we cannot rebuild needs a Wine name (Apple's
   D3DMetal loads as a Wine module and calls Wine functions such as `__wine_unix_call`), our
   runtime keeps an old-name alias for it. Aliases may exist only as strings inside our binaries;
   no file, folder, process, variable, registry key or other visible name may use them.
5. **Move to upstream's new engine first, then rename.** Upstream Whisky (frankea) shipped app
   3.8.0 to 3.10.2 (2026-11-12 to 11-16) and engine v4.8.3: Wine 11.19 with CrossOver's macOS
   patches, built by public CI from `frankea/winecx-gptk`. It runs D3DMetal (DirectX 12), draws
   Steam's store and menus, and supports controllers through SDL. Our v3.1.6 runtime cannot run
   D3DMetal at all (it lacks `gptkCapable`). So: first merge the upstream app changes and switch
   Ano to that engine, renamed as far as today's runtime is; then do the full rename on that
   engine's source. The rename is done once, on the engine we keep.
6. **Code-only names stay.** Names that exist only in the app's source (Swift types and file
   names such as `WineEnvironment`, which end up as strings in the app binary) and the repo name
   and URL `HighStormPVP/AnoWine` go on the allowlist. Everything a user can see is renamed.
7. **wine-mono is renamed, wine-gecko is dropped.** Mono's file, folder and product names are
   renamed; its internal assembly names (`WineMono.*`) go on the allowlist. Gecko is no longer
   shipped (Steam does not use it; programs that need it can get it through ano-tricks).
8. **Old traces are cleaned up.** On first launch of the renamed version the app deletes what
   earlier versions left that it owns and can remove without admin rights (for example
   `~/.cache/winetricks`, `/tmp/.wine-<uid>`, the `org.winehq.wine` cache folder, old defaults
   keys). The owner gets a one-off script for what needs admin rights (Rosetta's
   `/var/db/oah/.../wine*.aot` files).

Two further rules follow from these (stated by me, not asked):

- **Apple's files keep their contents.** Strings inside D3DMetal's own files (for example the
  `Wine builtin DLL` mark) are allowlisted; only the folders and copies the app creates are
  renamed.
- **License notices stay word for word.** Wine is LGPL; its copyright and authorship notices
  (for example "the Wine project authors" in version resources) are kept and allowlisted, and the
  runtime and app carry a notices file.

### Amended by the owner (2026-11-25, runtime 5.0.1)

On runtime 5.0.0 a Windows program could still find "wine" in three places: the copyright line
in every module's version resource, six old function names in ntdll's export table, and
`WINEESYNC` (or `WINED3DMETAL`) in the Mac-side environment of every engine process. The owner
asked for all three to go and chose (AskUserQuestion, 2026-11-25):

- **Decision 4, tightened: no other program can read a hidden alias.**
  - ntdll exports no old name. When a module with the old `Wine builtin DLL` mark (a closed part)
    loads, the loader rewrites the `__wine_` prefix inside that module's own memory to `__ano__`
    (the same length), and an export lookup for `__ano__<name>` answers with `__ano_<name>`.
    Apple's files on disk are never changed.
  - The old text our own binaries still need (the mark, the `__wine_` prefix, the unix-call
    table names, `WINED3DMETAL`, `WINEESYNC`) is stored encoded, so a file or memory scan for
    "wine" does not find it in our binaries. The CI gate can no longer see it either, so the
    D3DMetal stand-in test proves it still works.
  - `WINED3DMETAL` and `WINEESYNC` are set only in a process that is about to load a closed
    part's Mac library, not in every process.
- **License notices, narrowed.** The version-resource copyright line reads "Copyright (c)
  1993-2026 the authors listed in the file AUTHORS": the same authors, credited through the
  AUTHORS file in `share/ano/licenses/engine/`. License texts (LICENSE, AUTHORS, NOTICES.md, the
  Symbol font's license record, which points to the license and so stays intact) keep their
  words.
- 5.0.1 is built and checked now and published after the owner's D3DMetal test on 5.0.0.

## Goals

- **G1. No "wine" anywhere** that Ano ships or creates, case-insensitive, wherever the letters mean
  Wine (see "What counts" below), except entries on a written allowlist the owner has approved:
  - names of files, folders and symlinks: the app bundle, the installed runtime, bottles, caches,
    `/tmp`, logs, preferences;
  - process names, command lines and environments (variable names and values);
  - Mac system state: code-signing identifiers, embedded app identity, LaunchServices records,
    Mach service names, cache folders named after the app identity, the Rosetta translation
    cache (named after our files), the system log (category and subsystem names, our messages);
  - the registry of a new bottle: key paths, value names, value data, file headers;
  - text inside files: our binaries' strings (ASCII and UTF-16), scripts, plists, `.inf` and
    `.reg` files, version resources, the app's UI and localizations, log text, exports.
- **G2. Nothing that works breaks**: creating a bottle, Steam (install, log in, store, download,
  launch a game), DirectX through D3DMetal (with the owner's imported Game Porting Toolkit; it
  starts working with decision 5), DXMT and DXVK, controllers, winetricks verbs the app uses
  (`vcrun2019`, `dotnet48`, `d3dx9`, `d3dcompiler_47`, `xact`, `corefonts`, Windows-version and
  settings verbs), the per-bottle proxy (`Ano Proxy` workflow stays green), Open Terminal, crash
  handling, the `ano` CLI.
- **G3. Repeatable.** The rename is a script applied to pristine upstream source (Wine,
  winetricks, and any other component we rebuild), not a hand-edited fork, so a new Wine release
  can be renamed by running it again. A CI gate proves G1 on every runtime and app build.

## What counts as "wine"

- Counts: any token that refers to Wine — its programs, modules, folders, registry tree,
  variables, exports, markers, product names, URLs (`winehq.org`), messages ("Wine", "WINE"),
  build paths baked into binaries (`/Users/gcenx/.../wine-private/...`).
- Does not count: Windows API and other names that only contain the letters, such as `WinExec`,
  `WinEvent` (`SetWinEventHook`, `IProxyProviderWinEventSink`), and any similar case the gate
  finds. Each one goes on the allowlist with the reason "not Wine". Changing these would break
  Windows programs.

## Non-goals

- Converting existing bottles (decision 3). The app must recognise an old bottle and say plainly
  that it needs to be recreated, without touching it.
- Hiding Wine from anti-cheat or other detection. The goal is the name. Detection may change as a
  side effect; that is a risk to test, not a feature to promise.
- Renaming source-only identifiers that never reach a binary or a created file (C macros, header
  file names), unless that is the easiest way to keep a binary clean. The gate decides.

## Anti-goals

- Breaking a game, Steam, graphics or the proxy to remove a name. If a rename breaks something
  that cannot be fixed, the item goes on the allowlist with the owner's approval instead.
- A runtime that cannot be rebuilt from public source. Wine is LGPL; the rename script, patches
  and build workflow stay in this repo, and release notes link to them.

## Constraints

- Builds and tests run only on GitHub Actions `macos-15` runners (Mac runners are often not
  acquired; a job may take up to 6 hours). The dev machine is Windows.
- The runtime is x86_64 and runs under Rosetta. Never build arm64 Wine parts for it.
- Never make the app download anything from `github.io`; never build insecure TLS into the app.
  The owner's network inspects TLS.
- App and runtime must ship together. Each step that needs a newer app gets its own version
  feed, as upstream does: Ano-6 and Ano-7 read `dist/pages/WhiskyWineVersion.plist`, which stays
  on v3.1.6. The merged app (decision 5) reads a new feed for the new engine. The fully renamed
  runtime is **5.0.0** (a new major: bottles are incompatible) on its own feed, proposed
  `dist/pages/AnoRuntimeVersion.plist`. All feeds are served from raw.githubusercontent.com.
  (Upstream's engine is numbered 4.8.x, so Ano's renamed engine for step 1 keeps a 4.x number.)
- Publishing a runtime release needs the owner's yes each time. App test builds (`ano-test-N`)
  are pre-approved.
- Third-party parts and what we can do with each:

  | Part | Source | Today | After decision 5 | Can we rebuild? |
  |---|---|---|---|---|
  | Wine | WineHQ (LGPL) | 11.0 built by Gcenx; 7 files rebuilt by us | 11.19 + CrossOver patches, built by `frankea/winecx-gptk` CI | yes (this project) |
  | winetricks | GPL script | bundled in the app, lightly edited | same | yes |
  | DXMT 0.80 (`winemetal.dll`, `winemetal.so`) | open source | prebuilt in the runtime | same | yes, if needed |
  | DXVK 1.10.3 | open source, PE DLLs | prebuilt | same | yes, if needed |
  | wine-mono | WineHQ, open source | prebuilt in `share/wine` | renamed (decision 7) | names only |
  | wine-gecko | WineHQ, open source | prebuilt in `share/wine` | dropped (decision 7) | — |
  | D3DMetal (GPTK) | Apple, closed | imported by the user, not deployed | deployed into the engine | no: aliases |
  | MoltenVK 1.4.2, SDL2, gstreamer, other dylibs | open source | prebuilt | same | not needed unless the gate finds "wine" |

## How (decided parts)

1. **Step 1: upstream app and engine.** Merge upstream app 3.8.0 to 3.10.2 into Ano, keeping
   Ano's identity, renames and proxy. Switch the runtime base to upstream engine v4.8.3,
   repacked with today's renames (`ano-loader`, `ano-server`, `ano-core`, `ano-boot.exe`,
   `ano-device.exe`, no argument rewriting). The modules Ano rebuilds for those renames are
   rebuilt from the engine's own source (winecx), not from plain Wine 11.0. `gptkCapable` is set,
   so an imported Game Porting Toolkit is deployed. The proxy keeps working (`Ano Proxy` green).
   The owner tests Steam and a D3DMetal game. This is a release of its own.
2. **Step 2: build the whole engine ourselves.** Bring the `frankea/winecx-gptk` CI build into
   this repo (or a fork of it), unchanged, and prove it reproduces the step 1 engine file for
   file. Only then start renaming. This also lets Ano build future engine versions itself.
3. **Rename with a script** run over pristine upstream source before building: file names, build
   files, `.spec` exports, resources (`.rc`, `.po`), `.inf`, strings in C and Objective-C, registry
   paths, environment variable names, kernel object and window class names, device IDs, the
   builtin marker, the registry header, the embedded app identity, URLs. The same approach is
   used for winetricks and mono, and for DXMT and DXVK if the gate finds names in them.
4. **Aliases** live in ntdll (and any other module that needs them), as an explicit, commented
   list in the repo. Each entry names the closed part that needs it and how that was confirmed.
   CI has no copy of Apple's toolkit, so the D3DMetal check runs on the owner's Mac (a listing
   script for its imports, then a game).
5. **Runtime layout**: `Libraries/Wine/` → `Libraries/Ano/`; `lib/wine` → `lib/ano`;
   `share/wine` → `share/ano`; `WhiskyWineVersion.plist` inside the archive →
   `AnoRuntimeVersion.plist`; mono renamed, gecko removed (decision 7). Every Mach-O gets an
   explicit signing identifier without "wine". The loader's embedded app identity becomes name
   `Ano`, identifier `io.github.highstormpvp.Ano.core`, principal class `AnoApplication`
   (identifier is my call). The app's Game Porting Toolkit import deploys into the renamed folders.
6. **App**: every item in the appendix's app table, except code-only names (decision 6). That
   means the new environment and registry
   names, Terminal aliases (`ano-*` only), UI strings in all localizations, plist and defaults
   keys, log categories and text, diagnostics file names, the proxy's `ANO_WINE_DIR`, `GameDB.json`
   and launcher presets (they set Wine variables and DLL names), troubleshooting flows, the
   `wineglass` menu-bar symbol (replaced, my call), and the permission prompt text. No old-name
   fallbacks are needed for bottles (decision 3); old bottles are detected and refused with a
   clear message. First launch cleans up old traces (decision 8).
7. **winetricks** becomes `ano-tricks`: new variable names, its log `ano-tricks.log`, its cache in
   the app's cache folder (not `~/.cache/winetricks`), no upstream version check (today it calls
   raw.githubusercontent.com on every run, outside the bottle's proxy), no `W_PLATFORM=wine`.
8. **The gate**: `scan-wine-traces.sh` becomes a check that fails on any hit not on the allowlist
   (`scripts/anowine/wine-allowlist.txt`, one entry per line with its reason). Allowed
   categories, and only these: "not Wine" tokens (`WinExec`); aliases for closed parts; contents
   of Apple's files; license notices; code-only app names and the repo URL; mono's internal
   assembly names. Anything else needs the owner's approval to be added. It scans the runtime
   archive (names and contents), the app bundle, and a bottle after creation, a program run, the
   Wine tools and winetricks verbs, plus the Mac state listed under G1. It runs on every runtime
   build and app build. The existing checks (`check-ano-core.sh`, `check-ano-programs.sh`,
   `check-proxy.sh`) are updated to the new names and stay green.

## Proposed phases (my proposal; each becomes its own plan)

- **Plan 3a: upstream app and engine** (How 1). Merge app 3.8.0 to 3.10.2; engine v4.8.3
  repacked with today's renames; new version feed; `ano-test-N` plus a runtime release (owner's
  yes). The owner tests Steam, a D3DMetal game and the proxy.
- **Plan 3b: our own engine build** (How 2), unchanged names, proven equal to 3a's engine.
  Spikes: the Wine names D3DMetal needs (listing script on the owner's Mac); the false-positive
  list ("not Wine" tokens).
- **Plan 3c: the rename** (How 3 to 8): engine, mono, ano-tricks, app, cleanup, the gate. Runtime
  5.0.0 and the matching app ship together (owner's yes for the runtime).

Proxy Plans 2b (UDP) and 2c (kill switch) are not part of this; the owner decides their order
relative to 3a to 3c.

## Risks

- Games, launchers or anti-cheat that check for Wine (`wine_get_version`, `Software\Wine`) may
  behave differently, better or worse. Steam itself is tested in Plans 3a and 3c.
- winetricks verbs are written around Wine's file and registry names; the rename can break verbs.
  The verbs the app uses are tested in CI.
- The upstream merge (3.8.0 to 3.10.2) touches code Ano changed (identity, renames, proxy,
  Steam detection); conflicts are likely. Upstream says apps before 3.10.0 lack fixes the new
  engine needs, so the engine cannot ship without the merge.
- CrossOver's tree may carry its own product names (`CX_*`, "CrossOver"); the gate will find
  them, and the rule for them is the same as for Wine's (rename, or allowlist with approval).
- D3DMetal's needs may change with GPTK versions; the alias list may need updating.
- Debugging gets harder: logs and names no longer match Wine's documentation.
- Every Wine update means re-running the rename and the gate.
- CI time: a full Wine build plus the gate is long, and Mac runners are scarce.

## Left to the builder

- The rename technique, as long as the gate passes and the result is repeatable.
- New names where the rule is ambiguous (record them in the plan).
- How the app detects an old bottle.
- How third-party parts are packaged and, where needed, rebuilt.

## Appendix: inventory (2026-11-18)

Abbreviations: RT = `~/Library/Application Support/io.github.highstormpvp.Ano/Libraries`,
B = a bottle. "Seen" means observed by the trace scan on a Mac runner; the rest is from code.

### On the Mac

| What | Example | Source | Seen |
|---|---|---|---|
| Runtime folders in every process path | `RT/Wine/lib/wine/x86_64-unix/ano-core` | app layout; `lib/wine`, `share/wine` compiled into loader, server, ntdll | yes |
| Server folder and Mach service | `/tmp/.wine-501/server-<dev>-<ino>/` | server, ntdll | yes |
| App identity of the loader | signing ID and embedded plist `org.winehq.wine`, name `Wine`, class `WineApplication`; cache folder `.../C/org.winehq.wine/com.apple.metalfe` | `loader/wine_info.plist.in` | yes |
| Signing identifiers | `ano-loader` = `wine-…`, `ano-server` = `wineserver-…`, `winemac.so` = `winemac-…` etc. | build | yes |
| Rosetta cache files | `/var/db/oah/.../winemac.so.aot`, `winebus.so.aot`, `wineps.so.aot`, … | named after our files | yes |
| Loaded libraries | `winemac.so`, `winebus.so`, `winemac.drv`, `winebus.sys`, `winehid.sys`, … | runtime | yes |
| winetricks | `~/.cache/winetricks/<verb>/`, `$TMPDIR/winetricks.XXXXXXXX/`, `Ano.app/.../Resources/winetricks`, upstream version check | winetricks, app | yes |
| Environment (Mac side) | `WINEPREFIX`, `WINESERVER`, `WINEDEBUG`, `WINEDLLOVERRIDES`, `WINE`, `WINEARCH`, `WINELOADERNOEXEC`, `WINESERVERSOCKET`, `WINEPRELOADRESERVE`, `ANO_WINE_DIR`, `W_PLATFORM=wine` | app, ntdll, winetricks | yes |
| System log | `<WineWindow: …>` in AppKit messages; app log categories `WineKit`, `Wine`, `WhiskyWineInstaller`, `Winetricks` | winemac class names, app | yes (AppKit) |
| App files | `Metadata.plist` keys `wineConfig`, `wineVersion`; `activeWineDebugPreset`; `WinetricksCache.plist`; defaults `checkWhiskyWineUpdates`, `wineSectionExpanded`; diagnostics `wine.log`; temp `.reg` files with `Software\Wine` | app | code |
| App UI and bundle | about 54 English strings ("Open Wine Configuration", "Wine runtime"), all localizations, permission prompt "manage Wine bottles", `wineglass` symbol, `verbs.txt` (82), `GameDB.json` (330) | app | code |
| Clean | Dock and Cmd-Tab names (`ano-core`), system and kernel extensions, launch agents and daemons, login items, defaults domains, symlinks, the app bundle's extensions | — | yes |

### Inside a new bottle (seen)

| What | Count or example |
|---|---|
| Files named `wine*` | 51: `system32` and `syswow64` tools and modules (`winecfg.exe`, `winemac.drv`, `wined3d.dll`, `winevulkan.dll/.json`, `winemetal.dll`, …), `drivers/winebus.sys`, `winehid.sys`, `winexinput.sys`, `inf/winebus.inf` …, `spool/.../wineps.drv`, `wineps16.drv`, `winetricks.log` |
| Files whose contents say "wine" | 1,588 of 1,788: the `Wine builtin DLL` marker, `__wine_*` and `wine_get_*` exports, version info "Wine", build paths, `.inf` texts |
| Registry header | `WINE REGISTRY Version 2` in `system.reg`, `user.reg`, `userdef.reg` |
| Registry keys | 47: `Software\Wine\…` (LicenseInformation, Ports, AppDefaults, Debug, DllOverrides, Drivers, Fonts…), `WINEDBROWPRX.*` / `WINEDBRSTPRX.*` classes, "Wine Default Voice", print processor `wineps`, `Enum\ROOT\WINE\WINEBUS/WINEBTH/WINEUSB`, `Enum\WINEBUS\VID_845E…`, services `winebus`, `winehid` |
| Registry values | 134 × `"Author"="The Wine Project"`; 36 × `winegstreamer.dll`; `winebrowser.exe "%1"` link handlers; `winedbg --auto` debugger; `winemenubuilder` run entry; IE start page `https://www.winehq.org`; font paths under `…\Wine\share\wine\fonts`; "Wine HID device", `WinePlugPlay`, `WINEBUS\WINE_COMP_HID` |
| Windows environment | `WINECONFIGDIR`, `WINEDATADIR`, `WINEDLLDIR0`, `WINEHOMEDIR`, `WINELOADER`, `WINEUSERNAME`, `WINEUSERLOCALE`, `WINE_HOST_*` (which also copy the whole Mac environment: PATH, home, working folder) |
| Processes | `winecfg.exe` (bottle creation, settings button, winetricks); `winedbg.exe` on crashes, `winebrowser.exe` on links (not exercised) |

### Seen only from code (not visible in a quick run)

Thread names `wine_threadpool_worker` and others; pipes and objects `\pipe\wine_plugplay`,
`__wine_*`; window classes `Wine IME`, `WineDde*`, `__wine_*`; WMI answers (`WINE` BIOS
version, "Wine Disk Drive"); HID strings "The Wine Project"; pasteboard types
`org.winehq.builtin.*`; the notification `WineAppWillActivateNotification`; crash dialog and
`ano-boot` dialog texts; `ano-loader --version` prints `wine-11.0`; Wine's own log prefixes
`wine:` and `wineserver:`.
