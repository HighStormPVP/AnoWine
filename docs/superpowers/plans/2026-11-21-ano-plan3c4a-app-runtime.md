# Ano Plan 3c-4a — the app runs on engine 5.x

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Everything the app passes to or expects from the engine, the runtime folder, ano-tricks and a bottle uses the renamed engine's names (runtime 5.0.0); old bottles are recognised and refused untouched; Apple's D3DMetal still gets the two variables it reads, through a hidden alias inside the engine; the `ano` CLI creates a bottle and runs a program on engine 5.x in CI.

**Architecture:** A source lint (`check_app_runtime_names.py`, Hygiene) lists every runtime-interface name in the app's Swift literals and bundled JSON that still says Wine; it starts red and ends green. Each task updates the WhiskyKit tests to the new names first (red), then the code. The engine gets one patch (`patches/rename/0005`): ntdll copies `ANOD3DMETAL` and `ANOESYNC` to the names D3DMetal reads, inside the process only. A CI step builds the CLI, installs the 5.x engine artifact where the app keeps its runtime, and drives a bottle through WhiskyKit.

**Tech Stack:** Swift (WhiskyKit, the app, the CLI), Python 3 (lint), C (engine patch), GitHub Actions (`CI`, `AnoWine Hygiene`, `Ano Engine` 5.x, `Ano Proxy`).

**Spec:** `docs/superpowers/specs/2026-11-18-ano-full-rename-design.md`: decisions 3, 4, 6; How 5, 6, 7; G2. Owner's ruling 2026-11-21: D3DMetal's `WINED3DMETAL` and `WINEESYNC` via a hidden engine alias (the app sets `ANOD3DMETAL`, `ANOESYNC`).

## The rest of 3c-4 (roadmap)

| Plan | Scope |
|---|---|
| **3c-4a** (this) | runtime interface: layout, version plist and feed URL, environment, registry, Windows program and DLL names, engine output the app parses, ano-tricks and `verbs.txt`, the proxy's variables, the bottle file keys and old-bottle refusal, GPTK paths, the D3DMetal alias |
| 3c-4b | what users see and what the bundle carries: UI strings in every localization, log categories and text, CLI text, `Info.plist`, the `wineglass` symbol, troubleshooting flows, remediations, GameDB keys and text; the full source check (every literal and bundled file, code-only names allowlisted) |
| 3c-4c | first launch: cleanup of old traces (decision 8), the owner's admin script, app-level migrations (the update-check opt-out, the imported GPTK store, defaults keys) |

## Global Constraints

- **Names** (the engine's, 3c-1 to 3c-3): `Libraries/Ano` (was `Libraries/Wine`), `lib/ano`, `share/ano`, `Libraries/AnoRuntimeVersion.plist` (same keys); every `WINE*` variable → `ANO*` (`WINEPREFIX` → `ANOPREFIX`, `WINEDLLOVERRIDES` → `ANODLLOVERRIDES`, `WINE_LARGE_ADDRESS_AWARE` → `ANO_LARGE_ADDRESS_AWARE`, `WINED3DMETAL` → `ANOD3DMETAL`, `WINEESYNC` → `ANOESYNC`, `WINEMSYNC` → `ANOMSYNC`); `Software\Wine` → `Software\Ano`; programs `ano-cfg`, `ano-boot`, `ano-dbg`, `ano-console`, `ano-file`, `ano-path`; modules `anometal.dll`, `anod3d.dll`, `anocoreaudio.drv`; mark `Ano builtin DLL`; `ano-loader --version` → `ano-11.19`; engine messages `ano: …`; ano-tricks with `ANO`, `ANOSERVER`, `ANOPREFIX`, `ANO_BIN`, log `ano-tricks.log`.
- **Feed:** `DistributionConfig.versionPlistURL` = `<feedBaseURL>/AnoRuntimeVersion.plist`. The feed file itself is written in 3c-5, with the release (the `Ano Feeds` workflow checks feeds against published runtimes).
- **Allowed old names in the app**, and only these: `Wine builtin DLL` (the mark Apple's D3DMetal DLLs carry; the app accepts it beside `Ano builtin DLL`, allowlisted as `alias`); code-only names (decision 6). Apple's GPTK layout is found without naming its `lib/wine` folder.
- **Proxy:** `ANO_WINE_DIR` → `ANO_RUNTIME_DIR` (the rule would give `ANO_ANO_DIR`), in the app, `AnoNet/ano_net.c`, the native interposer and `check-proxy.sh` in one commit; `WINE_BIN` → `ANO_BIN`.
- **Old bottles** (decision 3): recognised before their `Metadata.plist` is decoded (`system.reg` starts `WINE REGISTRY`, or the plist has a `wine`-named key); shown as needing to be recreated; never written. Bottle file keys follow the rule (`wineConfig` → `anoConfig`, `wineVersion` → `anoVersion`, …).
- SwiftLint (120 columns, GPL header), SwiftFormat; `Localizable.xcstrings` LF with en-GB. `gh -R HighStormPVP/AnoWine`; RED pushed and watched before GREEN; `[skip ci]` plus dispatch. 3c-4a ships nothing; the app on `main` needs runtime 5.0.0 from here on.

## Review Focus

1. A `WINE*` variable, `Software\Wine` path or `lib/wine` path left in a rarely used route (Rockstar, audio, virtual desktop, fonts, diagnostics): the setting is silently ignored. The lint (Task 1) is the net.
2. An old bottle opened by the new app: decoded with defaults and then saved, which would damage it. Refusal must come before decoding, and nothing is written.
3. Apple's GPTK image still uses `redist/lib/wine`: the import must find D3DMetal there without the app naming that folder.
4. Steam detection and process listing with engine 5.x paths (`Libraries/Ano/bin/ano-loader`, `lib/ano/x86_64-unix/ano-core`).
5. A proxied bottle: the wrapper `ano-loader` first on PATH; ano-tricks needs `ANO_BIN` (3c-3 found what happens without it).

---

### Task 1: The runtime-names lint

**Files:** Create `scripts/anowine/check_app_runtime_names.py`, `scripts/anowine/test_check_app_runtime_names.py`. Modify `.github/workflows/AnoWineHygiene.yml`.

**Interfaces:** Produces `check_app_runtime_names.py [--root REPO]`: scans string literals of `Whisky/**/*.swift`, `WhiskyKit/Sources/**/*.swift`, `WhiskyCmd/**/*.swift` and the bundled JSON and plist resources under `WhiskyKit/Sources/WhiskyKit/**/Resources/`; reports `file:line: <name>` for each runtime name: a `WINE[A-Z0-9_]*` variable, `Software\Wine`, a path component `Wine`/`wine` passed to `appending(path:)` or in a `Libraries/Wine` / `lib/wine` / `share/wine` path, a Windows program `wine(cfg|boot|dbg|console|path|file|browser|menubuilder|server)`, a module `wine*.{dll,drv,sys,so,exe}`, `WhiskyWineVersion` as a file name, `winetricks` as a file or log name, `ANO_WINE_DIR`, `WINE_BIN`, `"wine-"` version parsing, `^wine:` patterns, the mark `Wine builtin DLL` without `Ano builtin DLL` on the same line. Exit 1 if any.

- [ ] **Step 1:** unit tests (one sample per pattern, a comment and an identifier not reported, `Wine builtin DLL` next to `Ano builtin DLL` allowed) and the Hygiene step. Push, dispatch Hygiene. Expected: unit tests pass; the lint step fails, listing the ~170 sites of the inventory.
- [ ] **Step 2: Commit** (`test: the app's runtime names lint (RED)`).

### Task 2: Runtime layout, version plist, feed, GPTK paths, module names

**Files:** `WhiskyKit/Sources/WhiskyKit/AnoWine/AnoWineRuntime.swift` (the folder names in one place: `runtimeFolderName = "Ano"`, `moduleFolderName = "ano"`, `versionPlistName = "AnoRuntimeVersion"`), `WhiskyWine/WhiskyWineInstaller.swift`, `Utils/DistributionConfig.swift` (and drop the legacy feed URL), `WhiskyWine/GPTKImporter*.swift`, `Wine/RockstarD3DLayout.swift`, `Wine/WineD3DSource.swift` (`anod3d.dll`), `Wine/Wine.swift` (`anometal.dll`, the builtin mark), `Whisky/DLLOverride.swift` (`anometal`), `Wine/VCRedistDetector.swift`; their tests.

**Interfaces:** Produces `AnoWineRuntime.runtimeFolderName`, `.moduleFolderName`, `.versionPlistName`, `.builtinMarks` (`["Ano builtin DLL", "Wine builtin DLL"]`); `WhiskyWineInstaller.binFolder` = `Libraries/Ano/bin`; GPTK deploys into `Libraries/Ano/lib/ano/...`; the GPTK store's own folder follows the rule (its migration is 3c-4c); Apple's image is searched for the folder that holds `libd3dshared.dylib` (or `D3DMetal.framework`), not by name.

- [ ] **Step 1:** tests to the new names (installer presence with `Libraries/Ano` and `AnoRuntimeVersion.plist`; a `Libraries/Wine` runtime reads as not installed; feed URL; GPTK deployment into `lib/ano`; an Apple image whose layout is `redist/lib/wine` still imports; DXMT deploys `anometal.dll`; a DLL with either mark is builtin; WineD3D source found by `anod3d.dll`). Push, dispatch CI. Expected: those tests fail.
- [ ] **Step 2:** the code. Dispatch CI. Expected: green, and the lint lists none of this task's names.
- [ ] **Step 3: Commit.**

### Task 3: Environment, registry, programs, engine output

**Files:** `Wine/WineEnvironment.swift`, `Whisky/BottleSettings.swift`, `Wine/MacOSCompatibility.swift` (drop `WINEFSYNC`: nothing reads it), `Wine/Wine.swift` (Terminal aliases: `export ANO=…`, aliases `ano-cfg`, `ano-boot`, `ano-console`, `ano-dbg`, `ano-file`, `ano-path`, none named `ano`; version parse `ano-`), `Wine/Wine+ProcessManagement.swift`, `Wine/Wine+ProgramSession.swift`, `Wine/Wine+RockstarNativeD3D11.swift`, `Wine/WineDLLOverrideRegistry.swift`, `Wine/WineRegistry.swift` (`ano-cfg`, `Software\Ano`), `Wine/WineVirtualDesktopRegistry.swift`, `Wine/RockstarD3DConsumers.swift`, `Wine/WineAudioRegistry.swift`, `Wine/WineAudioEndpoint.swift` (`anocoreaudio.drv`), `Wine/WineFontReplacements.swift`, `Wine/LauncherFixDetails.swift`, `Wine/LauncherPresets.swift`, `Audio/WineAudioTestProbe.swift`, `Diagnostics/DiagnosticExporter+Rockstar.swift`, `Troubleshooting/Checks/DiagnosticsEnhanceCheck.swift`, `Proxy/ProxyService+Selection.swift`, `Whisky/Views/Bottle/InputConfigSection.swift`, `Whisky/Views/Programs/ConsoleLogView.swift` (`^ano:`), `Diagnostics/Resources/patterns.json` (three patterns; `\bano\b`, not `ano`), `GameDatabase/Resources/GameDB.json` (`ANO_LARGE_ADDRESS_AWARE`), the graphics backend raw value `wined3d` → `anod3d`; their tests.

**Interfaces:** Produces environments whose names contain no `WINE`; `ANOD3DMETAL` and `ANOESYNC` where `WINED3DMETAL` and `WINEESYNC` were (Task 6 makes D3DMetal see them).

- [ ] **Step 1:** tests: every environment the builder makes for each backend, sync mode and launcher preset has no name containing `WINE` and the expected `ANO*` names; registry files the app writes use `Software\Ano`; bottle creation runs `ano-cfg`; the Terminal command defines only `ano-*` aliases; `ano-11.19` parses as 11.19; crash patterns match `ano: Unhandled page fault` and not `piano` or `Ano.app`. Push, dispatch CI. Expected: fail.
- [ ] **Step 2:** the code. Expected: green; the lint lists none of this task's names.
- [ ] **Step 3: Commit.**

### Task 4: ano-tricks and the proxy

**Files:** `Whisky/Utils/Winetricks.swift`, `Winetricks+Install.swift`, `Winetricks+InstalledVerbs.swift`, `WhiskyKit/.../Whisky/WinetricksVerbCache.swift`, `WhiskyKit/.../Utils/WinetricksInstallArguments.swift`, `Whisky.xcodeproj/project.pbxproj` (bundle `Libraries/ano-tricks`, not `winetricks`), `Libraries/verbs.txt`, `Libraries/winetricks` (deleted), `.github/workflows/CI.yml` (bundled resources `ano-tricks verbs.txt cabextract`), `scripts/anowine/make_ano_tricks.py` (`--verbs`: writes `verbs.txt` from `bash Libraries/ano-tricks list-all`, run on Linux), `Proxy/ProxyEnvironment.swift` (`ANO_RUNTIME_DIR`, `ANO_BIN`), `AnoNet/ano_net.c`, the native interposer, `scripts/anowine/check-proxy.sh`, `.github/workflows/AnoProxy.yml` (input `engine_run`: test against a 5.x engine artifact).

**Interfaces:** Consumes `Libraries/ano-tricks` (3c-3). Produces the app's ano-tricks call: `bash <Resources>/ano-tricks [--force] -q <verb>` with `ANOPREFIX`, `ANO=ano-loader`, `ANOSERVER`, PATH as today, `HOME`, and `ANO_BIN` for a proxied bottle.

- [ ] **Step 1:** tests: install arguments and environment (no `WINE`), installed verbs read from `ano-tricks.log`, the Terminal script; Hygiene: `verbs.txt` equals `ano-tricks list-all` and says no `wine` outside AutoHotkey; CI's bundled-resource check names `ano-tricks`; `check-proxy.sh` sets `ANO_RUNTIME_DIR`. Push, dispatch CI, Hygiene, and Ano Proxy with `engine_run` 44823000994. Expected: fail.
- [ ] **Step 2:** the code. Expected: CI, Hygiene and Ano Proxy (5.x engine) green; the lint lists none of this task's names.
- [ ] **Step 3: Commit.**

### Task 5: Bottle file keys and old bottles

**Files:** `Whisky/BottleSettings.swift` and the other Codable types with `wine` keys (`wineConfig`, `wineVersion`, `rockstarWineD3D`, `activeWineDebugPreset`, `hasWineDebugOutput`, `wineDebugPreset`, `isWineserverRunning`), `Whisky/BottleData.swift` or the bottle loader, `Whisky/Views/...` (an old bottle's row), `WhiskyCmd/Main.swift` (`list` and `run` refuse it); `WinetricksCache.plist` → `AnoTricksCache.plist`; tests with an old-bottle fixture.

**Interfaces:** Produces `Bottle.isFromOldRuntime` (true when `system.reg` begins `WINE REGISTRY` or `Metadata.plist` has a key containing `wine`), checked before decoding; such a bottle is listed, cannot be opened or run, and is never written (its files' modification times and bytes unchanged).

- [ ] **Step 1:** tests: a new bottle's `Metadata.plist` has no `wine` key; an old fixture (`WINE REGISTRY` header and `wineConfig`) is flagged, its settings not decoded, its files untouched after load, refresh and a run attempt; the CLI refuses it with a message naming the fix (recreate the bottle). Push, dispatch CI. Expected: fail.
- [ ] **Step 2:** the code. Expected: green.
- [ ] **Step 3: Commit.**

### Task 6: D3DMetal's two variables, a hidden alias in the engine

**Files:** Create `scripts/anowine/patches/rename/0005-ano-env-aliases.patch` (ntdll's Unix side, at process start: for each pair in a commented list, `ANOD3DMETAL` → `WINED3DMETAL` and `ANOESYNC` → `WINEESYNC`, if the new name is set, set the old one in this process's own environment, after the environment handed to child processes and to Windows is built, so neither carries it). Modify `scripts/anowine/aliases.txt` (the two names, "provisional until the owner's ano-gptk-wine-names.txt"), `scripts/anowine/wine-allowlist.txt` (the two names as `alias`, strings inside ntdll.so only), `scripts/anowine/check-aliases.sh` or a new `check-env-aliases.sh`, `.github/workflows/AnoEngine.yml` (5.x check).

**Interfaces:** Produces the engine behaviour: a Windows program started with `ANOD3DMETAL=1 ANOESYNC=1` runs with `WINED3DMETAL=1 WINEESYNC=1` in its own Unix environment (what D3DMetal's `getenv` sees) and in nobody else's: not in its exec environment (`ps -E`), not in a child process's, not in the Windows environment (`cmd /c set`).

- [ ] **Step 1:** the check: a Windows program started with `ANOD3DMETAL=1 ANOESYNC=1` prints its Windows environment (`cmd /c set`) and starts a child that waits; `ps -E` on both; and a probe dylib (x86_64, built in the job) injected into that one launch only (`DYLD_INSERT_LIBRARIES` on the command, per the spike rule) prints `getenv("WINED3DMETAL")` and `getenv("WINEESYNC")` from an exit handler, which is what D3DMetal's `getenv` sees. Expected before the patch: the probe prints nothing set. Dispatch `Ano Engine` 5.0.0 with `engine_run` (no rebuild): fail.
- [ ] **Step 2:** the patch; dispatch `Ano Engine` 5.0.0 with a rebuild. Expected: the alias present inside the program, absent everywhere else; every other 5.x check green.
- [ ] **Step 3: Commit.**

### Task 7: The CLI drives a bottle on engine 5.x

**Files:** Create `scripts/anowine/check-app-on-engine.sh`. Modify `.github/workflows/AnoEngine.yml` (5.x check: build the `WhiskyCmd` scheme, install the engine artifact's `Libraries` into `~/Library/Application Support/io.github.highstormpvp.Ano/Libraries`, run the check).

**Interfaces:** Consumes Tasks 2 to 6 and the engine artifact. Produces `check-app-on-engine.sh <ano CLI>`: `ano create T`; `ano run T C:\windows\system32\cmd.exe /c echo ok` prints `ok`; the bottle's `user.reg` has the keys the app writes under `Software\Ano` and none under `Software\Wine`; `ano shellenv T` names only `ANO*` variables; the gate passes over the bottle; an old-bottle fixture added with `ano add` is refused and unchanged; `ano list` works.

- [ ] **Step 1:** the step and the script before Tasks 2 to 5 are merged into the CI app build (if they already are, the old-bottle fixture and the gate are the red part). Expected: fail.
- [ ] **Step 2:** fixes until green. The lint (Task 1) is green too.
- [ ] **Step 3: Commit.**

### Task 8: Report

- [ ] `spikes/REPORT.md` "## Plan 3c-4a": what the app now expects of the runtime, the alias and how it was checked, old-bottle refusal, what is left for 3c-4b and 3c-4c, what the owner must test (D3DMetal with the alias, once `ano-gptk-wine-names.txt` confirms the names). Workspace `CLAUDE.md`. Commit.
