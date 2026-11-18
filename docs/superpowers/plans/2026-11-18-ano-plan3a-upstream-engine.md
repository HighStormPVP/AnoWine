# Ano Plan 3a — Upstream app 3.10.2 and engine v4.8.3

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ano runs on upstream's GPTK-capable engine (Wine 11.19 with CrossOver's macOS patches, upstream v4.8.3), repacked with Ano's program names as runtime **4.9.0**. The app carries upstream app 3.8.0 to 3.10.2 and ships as test build **Ano-8**.

**Architecture:** The runtime is upstream's published v4.8.3 `Libraries.tar.gz`, with today's renames applied by `repack-runtime.sh`. The modules that start a renamed program by name are rebuilt by `build-modules.sh` from the engine's own source: dappermint/winecx at the engine's commit, plus the engine's one out-of-tree patch, plus Ano's three patches rebased onto it. The app is a merge of upstream tag `app-v3.10.2` that keeps Ano's identity, names, proxy and Steam parser. Ano-8 reads a new feed, `WhiskyWineVersion-v4.plist`; Ano-6 and Ano-7 keep reading the frozen v3.1.6 feed.

**Tech Stack:** bash; Wine/winecx autotools build (Rosetta, pinned llvm-mingw, Homebrew bison); GitHub Actions `macos-15` and `ubuntu-latest`; Swift 6 (WhiskyKit, SwiftUI); git merge.

**Spec:** `docs/superpowers/specs/2026-11-18-ano-full-rename-design.md`: decision 5, "How" step 1 and "Plan 3a". Upstream's own engine procedure is in `docs/ReleaseWorkflow.md` ("Wine Libraries release") at tag `app-v3.10.2`.

## Global Constraints

- **Pinned inputs.** Use these values exactly:

  | What | Value |
  |---|---|
  | Upstream engine | `https://github.com/frankea/Whisky/releases/download/v4.8.3/Libraries.tar.gz`, sha256 `08ffabd7b7c352470faee2b1d51061b341316e401439ca805c5302acc2fb8818` |
  | Engine source | `https://github.com/dappermint/winecx.git` at `9f3f6447844add700bc0dde650e4f398fd5f69ab` (its `VERSION` file reads `Wine version 11.19`) |
  | Engine's out-of-tree patch | `patches/0001-ntdll-kernelbase-keep-the-fiber-pointer-at-gs-0x20-on-macOS.patch` from `frankea/winecx-gptk` at `12af86593bc5195c5015ca460dc1bbc8e81f3b13`, sha256 `d36bfa79c78b0fac47e24aa77d397d73548620a87ae74f4914b58b1194ddd861` |
  | Engine build settings that reach our modules (from winecx-gptk `build.yml` at that commit) | `MACOSX_DEPLOYMENT_TARGET=15.0`, `ac_cv_func_pipe2=no`, `CFLAGS="-O3 -Werror=unguarded-availability-new"`, `CROSSCFLAGS=-O3`, `--enable-archs=i386,x86_64 --disable-tests` |
  | Ano runtime | version `4.9.0`, release tag `v4.9.0` |
  | Upstream app | tag `app-v3.10.2` (`b9006143`) |
  | New feed (Ano-8 and later) | `dist/pages/WhiskyWineVersion-v4.plist`, served as `https://raw.githubusercontent.com/HighStormPVP/AnoWine/main/dist/pages/WhiskyWineVersion-v4.plist` |
  | Frozen feed (Ano-6, Ano-7) | `dist/pages/WhiskyWineVersion.plist`: version 3.1.6, sha256 `412035519d2df986aebb5c3a72c5dd6b00162d3b5aa52c1fff1713928b521ead`. **Never changes in this plan.** |

- Today's names stay. `ano-loader`, `ano-server`, `ano-core`, `ano-boot.exe` and `ano-device.exe` are kept, and no process argument is rewritten. No new user-visible "wine" name is added. Folders such as `lib/wine` and `share/wine`, and the feed file names, keep their names until Plan 3c.
- The runtime is x86_64 and runs under Rosetta. Never build arm64 Wine parts.
- The app never downloads from `github.io`, and never builds insecure TLS. Feeds come from raw.githubusercontent.com, runtimes from `https://github.com/HighStormPVP/AnoWine/releases/download/v<version>/Libraries.tar.gz`.
- Publishing runtime v4.9.0 needs the owner's yes; that is the stop between Task 2 and Task 3. The app test build `ano-test-8` is pre-approved (pre-release, `Ano-8.zip`).
- Any change that affects how processes appear in `ps` must keep Steam detection working: `WineSteamClientDriver.windowsImageName(inCommand:)` and `SteamLauncher.steamPIDs(inProcessListing:)`.
- Swift files:
  - every file starts with the exact upstream GPL header ("This file is part of Whisky.");
  - lines are at most 120 characters;
  - SwiftFormat spacing applies (`from ..< end`).
- `Whisky/Localizable.xcstrings`:
  - LF line endings;
  - an en-GB entry for every key (`scripts/british-english.py`);
  - Ano wording (`scripts/anowine/rebrand_strings.py --check` passes).
- Scripts are committed with LF endings and git mode 100755 (`check-hygiene.sh`). Edit backslash-heavy text with the Edit/Write tools, not heredocs.
- CI only; the dev machine is Windows.
  - `gh` always takes `-R HighStormPVP/AnoWine`.
  - A task is done when its workflow runs are green.
  - RED is pushed and watched before GREEN.
  - Mac runners are often "not acquired": re-run with `gh run rerun <id> --failed -R HighStormPVP/AnoWine`.
  - CI.yml cancels its own in-progress run on every push. To push only scripts or workflows while CI matters, put `[skip ci]` in the message and dispatch the workflow you need. `[skip ci]` skips every push-triggered workflow.
- Commits go to `main` of the fork, the established workflow. Each commit ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Decisions made in this plan (not in the spec; list them for the owner)

- **Version 4.9.0.** Upstream calls this engine 4.8.3 and already has a 4.8.4 beta. A version of our own avoids reusing a number for different contents; the app only compares numbers within Ano's own feed.
- **Feed file names.** The new feed keeps upstream's name `WhiskyWineVersion-v4.plist`, which keeps the merge simple. Plan 3c renames all feeds.
- **Rebuilt modules.**
  - Ano's three patches are rebased in place onto the engine source. Runtime v3.1.6 stays reproducible from tag `v3.1.6`.
  - The Windows-side (PE) modules are still built with the pinned llvm-mingw, not Homebrew's unpinned mingw-w64.
  - `ntdll.so`, the one Mac-side module, must match the engine's exports, imports and minimum macOS (Task 1, `check-modules.sh`).
- **Upstream workflows.** Upstream's new `CodeQL.yml` and `Stale.yml` run only in `frankea/Whisky`. CodeQL would hold a Mac runner for 35 minutes on every push.
- **App version.** `MARKETING_VERSION` becomes 3.10.2, the upstream base.
- **Steam detection.** A line `…/bin/ano-loader <image>` counts as a Windows process. On the new engine, a program the app starts directly keeps the loader's path for its whole life; see Task 4.

## Found while planning (for Plan 3c, no action here)

- CrossOver's "CW HACK 22144" (`dlls/ntdll/unix/loader.c`) links the loader into `$TMPDIR/winetemp-<inode>-…/<AppName>` and sets `WINEPRELOADERAPPNAME`. Without Wine's preloader it does this only when `WINEDLLPATH` is set, which Ano does not do.
- The engine ships `bin/wineloader` beside `bin/wine` and `bin/wine64`; the repack removes all three.
- The engine bundles more libraries than today's runtime (SDL2, ffmpeg, gstreamer, `lib/gptk-video`). The 3c gate scans them.

## Review Focus

1. **Bottles the owner made on 3.1.6** (Wine 11.0, Steam installed), opened by 4.9.0 (Wine 11.19 plus CrossOver), must update in place and keep working. Test: Task 1 runs `check-ano-programs.sh --upgrade-from` with v3.1.6.
2. **Process command lines on the new engine.** A program the app starts runs as the `bin/ano-loader` link; children run as `ano-core`. Steam detection must find both. Tests: Task 1 adds a command-shape check to `check-ano-core.sh --boot`; Task 4 adds parser tests from its real output.
3. **The proxy on the new engine.** The engine's server and msync changes, the symlinked loader and `ANO_WINE_DIR` together must not let anything connect directly. Tests: Task 2 runs `check-proxy.sh` on the unpublished build; Task 5 runs it on the published 4.9.0.
4. **Merged upstream code that starts Wine** without Ano's proxy environment, or by an old program name. Tests: Task 3, audits B and E; for every new launch site, the proxy-environment tests that exist today must cover it, or a test is added.
5. **The update path.** Ano-8 with 3.1.6 installed must be offered 4.9.0, and Ano-6 and Ano-7 must never be. Test: Task 3, `EngineFeedTests` (adapted) plus the check that the frozen feed is unchanged.

---

## Part A — the engine (scripts and workflows only)

### Task 1: Runtime 4.9.0, engine v4.8.3 with Ano's names

**Files:**
- Create: `scripts/anowine/check-modules.sh` (mode 755)
- Create: `scripts/anowine/patches/engine/0001-ntdll-kernelbase-keep-the-fiber-pointer-at-gs-0x20-on-macOS.patch` (byte copy of the pinned file)
- Modify: `scripts/anowine/patches/ano-programs.patch`, `ntdll-no-proctitle.patch`, `ntdll-ano-core.patch` (rebased onto the engine source)
- Modify: `scripts/anowine/build-modules.sh`, `scripts/anowine/repack-runtime.sh`, `scripts/anowine/check-ano-core.sh`
- Modify: `.github/workflows/AnoWineRuntime.yml`

**Interfaces:**
- Produces: the `anowine-runtime` artifact (`Libraries.tar.gz`) of workflow `AnoWine Runtime`, with this layout:
  - `Libraries/Wine/bin/` holds exactly `ano-loader` (a symlink to `../lib/wine/x86_64-unix/ano-core`) and `ano-server` (a real file);
  - `Libraries/WhiskyWineVersion.plist` has version 4.9.0, `gptkCapable` true, `dxvkVersion` 1.10.3, `dxmtVersion` 0.80, and no `sha256`.
- Produces for Task 2: the run ID of the first green `AnoWine Runtime` run, written in the ledger.
- Produces for Task 4: the "Wine processes seen" listing from that run's `check-ano-core.sh --boot` step, written in the ledger.
- Unchanged interfaces:
  - `build-modules.sh <out-dir> [patch ...]` keeps its usage. The engine's own patches are applied first, then the given ones.
  - `check-ano-core.sh <Libraries-dir> [--boot]` keeps its usage.

- [ ] **Step 1: Write the failing test `check-modules.sh <modules-dir> <engine-ntdll.so>`**

Same `check()` and `ok`/`FAIL` style as `check-ano-core.sh`. `<modules-dir>` is `build-modules.sh`'s output, and the file under test is `<modules-dir>/Wine/lib/wine/x86_64-unix/ntdll.so`. It exits non-zero on any FAIL. Checks:

| Check text | Passes when |
|---|---|
| `ntdll.so is x86_64 only` | `lipo -archs` prints `x86_64` |
| `ntdll.so needs macOS 15.0, like the engine's` | the `minos` of the `LC_BUILD_VERSION` load command is `15.0` in both files |
| `ntdll.so exports what the engine's exports` | `nm -gU` symbol names, sorted, are identical |
| `ntdll.so imports what the engine's imports, except _setprogname` | sorted `nm -u` of ours equals the engine's with `_setprogname` removed |
| `ntdll.so starts ano-core` | `grep -aq "%s%s/ano-core"` |

- [ ] **Step 2: Extend `check-ano-core.sh` and wire the checks into `AnoWine Runtime`**

New static checks in `check-ano-core.sh`:
- `bin/ano-loader links to ../lib/wine/x86_64-unix/ano-core`: `[ -L "$BIN/ano-loader" ]`, and `readlink` prints exactly that target.
- `bin holds only ano-loader and ano-server`.

Changed `--boot` checks:
- `nothing ran as wine, wine64, wineloader or wineserver`;
- `no process command starts with a Windows path`, with the pattern widened to `^ano-(core|loader) +[A-Za-z]:`.

New `--boot` check, `every Wine process command starts with the ano-core or ano-loader path`: there must be no line in `ps.txt` that matches `^ano-(core|loader) ` but not `^ano-(core|loader) +/[^ ]*/ano-(core|loader)( |$)`. BSD grep has no `\S`. CI paths contain no spaces.

Changes to `AnoWineRuntime.yml`:
- Add `scripts/anowine/check-modules.sh` to the push paths.
- Job `modules`, after Build:
  - step "Engine ntdll.so": `actions/cache@v5` with key `engine-v4.8.3-08ffabd7b7c3`; download the upstream engine if not cached; verify its sha256; extract only `Libraries/Wine/lib/wine/x86_64-unix/ntdll.so`;
  - step "Modules match the engine": `bash scripts/anowine/check-modules.sh "$RUNNER_TEMP/modules" <that ntdll.so>`.
- Job `build`:
  - the old runtime used by `--upgrade-from` becomes v3.1.6 (`https://github.com/HighStormPVP/AnoWine/releases/download/v3.1.6/Libraries.tar.gz`), sha256-verified;
  - new step "Checks reject runtime 3.1.6", right after that download: `if bash scripts/anowine/check-ano-core.sh "$RUNNER_TEMP/old/Libraries"; then echo "::error::check-ano-core accepted a 3.1.x runtime"; exit 1; fi`. This proves the new layout checks can fail.

- [ ] **Step 3: Push RED and watch it fail**

```bash
git add scripts/anowine/check-modules.sh scripts/anowine/check-ano-core.sh .github/workflows/AnoWineRuntime.yml
git commit -m "test: runtime modules must match engine v4.8.3; layout checks for the linked loader"
git push && gh run watch -R HighStormPVP/AnoWine $(gh run list -R HighStormPVP/AnoWine -w "AnoWine Runtime" -L 1 --json databaseId -q '.[0].databaseId')
```
Expected: job `modules` fails at "Modules match the engine" with `FAIL ntdll.so needs macOS 15.0, like the engine's` and `FAIL ntdll.so exports what the engine's exports`; job `build` is skipped.

- [ ] **Step 4: Vendor the engine patch.** Download it from the pinned commit, check sha256 `d36bfa79…ddd861` and LF endings, and commit it unchanged.

- [ ] **Step 5: Rebase Ano's three patches onto winecx `9f3f644` with the engine patch applied.**

Each must apply with `patch -p1 --forward --batch --fuzz=0`.

Known differences (found while planning with `patch --dry-run` against the winecx tarball):
- `programs/wineboot/Makefile.in` now reads `IMPORTS   = uuid rpcrt4 advapi32 ws2_32 kernelbase`;
- `set_process_name` in `dlls/ntdll/unix/env.c` declares `const char *p;`;
- every other hunk applies, only with offsets.

Regenerate the patches so they carry no offsets or fuzz. Verify on Windows: unpack the winecx tarball (`https://codeload.github.com/dappermint/winecx/tar.gz/<commit>`) into a scratch directory, then dry-run the engine patch followed by the three Ano patches. Expected: every hunk succeeds, with no "fuzz" and no "offset".

- [ ] **Step 6: Switch `build-modules.sh` to the engine source**

- Fetch the source by commit:
  - `git init`;
  - `git fetch --depth 1 https://github.com/dappermint/winecx.git 9f3f6447844add700bc0dde650e4f398fd5f69ab`;
  - `git checkout FETCH_HEAD`;
  - fail unless `git rev-parse HEAD` equals the pin and `VERSION` reads `Wine version 11.19`.
- Apply `patches/engine/*.patch` (sorted), then the patches given as arguments.
- Configure:
  - under `arch -x86_64`, as today;
  - with the pinned engine build settings;
  - with `--without-*` for libraries these modules do not use, so configure needs only Homebrew bison and llvm-mingw;
  - drop `--enable-win64` and `--with-unwind`; the engine passes neither.
- `TARGETS` and `OUTPUTS` stay the same 10 files. Update the header comment, which now says the modules come from the engine source, not plain Wine 11.0.

- [ ] **Step 7: Switch `repack-runtime.sh` to engine v4.8.3**

- `BASE_URL` and `BASE_SHA256` become the pinned engine. The version becomes 4, 9, 0.
- Layout guards (fail closed, as today):
  - `bin/wine`, `bin/wine64` and `bin/wineloader` are symlinks to `../lib/wine/x86_64-unix/wine`;
  - `bin/wineserver` and `lib/wine/x86_64-unix/wine` are real files.
- Renames:
  - remove the three links;
  - `bin/wineserver` → `bin/ano-server`;
  - `lib/wine/x86_64-unix/wine` → `ano-core`;
  - create `bin/ano-loader` as `ln -s ../lib/wine/x86_64-unix/ano-core`. It must be a symlink: Wine's loader looks for `ntdll.so` beside its resolved path, so a copy in `bin` fails.
- The module replacement and the "wine.inf differs in exactly 4 lines" guard stay as they are.
- Plist:
  - set the version and delete `sha256`, as today;
  - then fail unless `gptkCapable` is true, `dxvkVersion` is `1.10.3` and `dxmtVersion` is `0.80`.
- "verify layout" also fails unless `bin` holds exactly `ano-loader` and `ano-server`.

- [ ] **Step 8: Update `AnoWineRuntime.yml` for 4.9.0**

- Change 3.1.6 to 4.9.0 in the header comment, the `publish` input description, the job name and `gh release create v4.9.0`.
- The title becomes `Ano Wine runtime v4.9.0`.
- Notes, exact text:

> Ano's Wine runtime 4.9.0, for Ano 8 and later (earlier Ano versions stay on v3.1.6). Upstream frankea/Whisky engine v4.8.3: Wine 11.19 with CrossOver's macOS patches (dappermint/winecx 9f3f644), built by frankea/winecx-gptk CI at 12af865. Ano's names: the loader runs as ano-core and bin/ano-loader links to it, wineserver is ano-server, wineboot.exe is ano-boot.exe and winedevice.exe is ano-device.exe, and ntdll.so neither renames its process nor overwrites its arguments. The modules that start these by name are rebuilt from the engine's own source with scripts/anowine/patches/. GPTK-capable: D3DMetal deploys when you import Apple's Game Porting Toolkit. SHA-256: $(sha256sum out/Libraries.tar.gz | cut -d' ' -f1)

- [ ] **Step 9: Push GREEN and watch it pass**

```bash
git add scripts/anowine/ .github/workflows/AnoWineRuntime.yml
git commit -m "feat: runtime 4.9.0 is upstream engine v4.8.3 with Ano's names"
git push   # then gh run watch the new AnoWine Runtime run, as in Step 3
```

Expected, all jobs green:
- `modules`: every `check-modules.sh` line is `ok`.
- `build`:
  - the repack prints `SHA-256: …`;
  - every `check-ano-core.sh --boot` line is `ok`, the new checks included;
  - `check-ano-programs.sh` is all `ok`, with `--upgrade-from` v3.1.6;
  - "Checks reject runtime 3.1.6" passes.

Write the run ID and the "Wine processes seen" listing into the ledger. If a check fails, use superpowers:systematic-debugging. Never loosen a check to pass; a loosened check needs a ledgered ruling that says why.

### Task 2: Proxy test against the unpublished build

**Files:**
- Modify: `.github/workflows/AnoProxy.yml`

**Interfaces:**
- Consumes: the Task 1 run ID (artifact `anowine-runtime`).
- Produces: a new `workflow_dispatch` input `runtime_run_id` (string, default empty). When it is empty, the published runtime in `RUNTIME_URL` is used, as today.

- [ ] **Step 1: Add the input.**
  - Add `actions: read` to permissions.
  - Add a step with `if: inputs.runtime_run_id != ''` that runs `actions/download-artifact@v8` with `name: anowine-runtime`, `run-id: ${{ inputs.runtime_run_id }}` and `github-token: ${{ github.token }}`.
  - Put the existing cache and download steps under the opposite `if`.
  - Both paths unpack into `$RUNNER_TEMP/runtime`. Then print `Libraries/WhiskyWineVersion.plist`'s version with PlistBuddy.
- [ ] **Step 2: Commit and push with `[skip ci]`** (`test: proxy check can run on an unpublished runtime build [skip ci]`). Then dispatch the default path: `gh workflow run AnoProxy.yml -R HighStormPVP/AnoWine`. Expected: green, version printed as 3.1.6. The default path is unchanged.
- [ ] **Step 3: Dispatch on the build:** `gh workflow run AnoProxy.yml -R HighStormPVP/AnoWine -f runtime_run_id=<Task 1 run ID>`. Expected:
  - version printed as 4.9.0;
  - `check-proxy.sh` exits 0;
  - no `FAIL` lines;
  - the same number of `ok` lines as the last green run on v3.1.6.

  A failure is a finding about the engine, not the test. Use systematic-debugging, starting with `ano-server` (msync) and the symlinked loader against `ANO_WINE_DIR`.

### Stop: publish runtime v4.9.0 (needs the owner's yes)

Send this, with the Task 1 and Task 2 run links:

> The new runtime is built and passes every check: bottles start, ano-boot and ano-device work, bottles from 3.1.6 update, and the proxy test passes on it. May I publish it as release v4.9.0? Nothing changes for Ano-6 or Ano-7: only Ano-8 will read it. I recommend yes.

After the yes:
- run `gh workflow run AnoWineRuntime.yml -R HighStormPVP/AnoWine -f publish=true` and watch it;
- expected: release `v4.9.0` with `Libraries.tar.gz`, and job `digest` green (it still checks the frozen feed, v3.1.6);
- write the published asset's sha256 into the ledger, from the publish log or `gh release download v4.9.0 -p Libraries.tar.gz` plus `sha256sum`. Tasks 3 and 5 use it.

---

## Part B — the app

### Task 3: Merge upstream app 3.10.2, reading the 4.9.0 feed

**Files:** the merge. Conflicts in a trial `git merge-tree` on 2026-11-18:
- `Whisky.xcodeproj/project.pbxproj` (4 hunks);
- `Whisky/Localizable.xcstrings` (8);
- `Whisky/Utils/Winetricks+Install.swift`;
- `WhiskyKit/Sources/WhiskyKit/Steam/SteamClientDriver.swift`;
- `WhiskyKit/Sources/WhiskyKit/Utils/DistributionConfig.swift`;
- `WhiskyKit/Sources/WhiskyKit/Whisky/BottleSettings.swift`;
- `WhiskyKit/Sources/WhiskyKit/Whisky/ShortcutCreator.swift`;
- `WhiskyKit/Tests/WhiskyKitTests/DistributionConfigTests.swift` (2);
- `dist/pages/appcast.xml`, `dist/pages/index.html`;
- `docs/DEPENDENCIES.md`.

Also edited in the merge commit:
- `dist/pages/WhiskyWineVersion-v4.plist` (upstream adds it);
- `WhiskyKit/Tests/WhiskyKitTests/EngineFeedTests.swift` (upstream adds it);
- `.github/workflows/CodeQL.yml` and `Stale.yml` (upstream adds them);
- `README.md`.

**Interfaces:**
- Consumes: the published v4.9.0 sha256 (from the Stop).
- Produces:
  - `DistributionConfig.versionPlistURL` = the new feed URL;
  - `DistributionConfig.legacyVersionPlistURL` = `https://raw.githubusercontent.com/HighStormPVP/AnoWine/main/dist/pages/WhiskyWineVersion.plist`;
  - `DistributionConfig.releasesPageURL` = `https://github.com/HighStormPVP/AnoWine/releases`, with `releasesBaseURL` = `"\(releasesPageURL)/download"`;
  - `baseURL` stays `https://highstormpvp.github.io/AnoWine`; it is used only by the appcast, and Sparkle is off;
  - `dist/pages/WhiskyWineVersion-v4.plist` with version 4.9.0, sha256 of the published asset, `gptkCapable` true, `dxvkVersion` 1.10.3, `dxmtVersion` 0.80.

A merge brings upstream's tests together with its code, so this task has no RED push of its own. Its evidence is the full suite plus audits A to F. Where a merged upstream test encodes Whisky's identity, URLs or Wine program names, adapt it to Ano's values in the merge commit. Any other failing test is a merge bug.

- [ ] **Step 1: Merge.** Run `git merge --no-ff app-v3.10.2`. If the tag is missing, run `git fetch upstream --tags` first.
- [ ] **Step 2: Resolve conflicts with these rules**

| File | Rule |
|---|---|
| `project.pbxproj` | `MARKETING_VERSION = 3.10.2`. Ano's `PRODUCT_BUNDLE_IDENTIFIER` (`io.github.highstormpvp.Ano`, `.Thumbnail`) and `PRODUCT_NAME = Ano` stay. |
| `Localizable.xcstrings` | Keep every key from both sides; where both changed a key, take upstream's text. Then run `rebrand_strings.py`, then `british-english.py`, then convert to LF. |
| `Winetricks+Install.swift` | Upstream's `WinetricksInstallArguments.arguments(verb:winetricksPath:)`, with Ano's `ProxyEnvironment.applying(proxy, to: [...])` wrapped around the environment. Check that the helper keeps Ano's `--force -q` for `vcrun` verbs. |
| `SteamClientDriver.swift` | Both: upstream's `hostSteamPIDs()` requirement and implementation, plus Ano's `command=` parser and its doc comment. Drop upstream's `comm=` doc text. |
| `DistributionConfig.swift` | Upstream's structure with Ano's values (see Interfaces). Keep Ano's comment about why feeds come from raw.githubusercontent.com. |
| `DistributionConfigTests.swift` | Ano's expected values. |
| `BottleSettings.swift` | Keep Ano's comment line. |
| `ShortcutCreator.swift` | Upstream's localized alert (`osascript -e \(shellQuoted(alert))`); its title and message strings say Ano after the rebrand. |
| `appcast.xml`, `index.html` | Ano's. |
| `DEPENDENCIES.md` | Ano's file, plus a new first section, "Bundled in runtime 4.9.0 (Ano 8 and later)". It is upstream's v4.8.3 table plus one row for Ano's renames (`scripts/anowine`). The 3.1.6 section is marked "frozen, for Ano 6 and 7". The archive integrity table gets 4.9.0 and 3.1.6. |
| `WhiskyWineVersion-v4.plist` | Ano's values (see Interfaces), never upstream's. |
| `EngineFeedTests.swift` | Legacy URL is Ano's raw URL; `legacy.version == SemanticVersion(3, 1, 6)`; `current.version == SemanticVersion(4, 9, 0)`; `current.gptkCapable == true`; `current.sha256?.count == 64`. |
| `CodeQL.yml`, `Stale.yml` | Add `if: github.repository == 'frankea/Whisky'` to every job. |
| `README.md` | Keep Ano's text. Upstream's new engine, D3DMetal and controller paragraphs stay, with "Whisky" read as "Ano"; links to frankea/Whisky issues stay. |

- [ ] **Step 3: Audits. Each must give exactly the expected result before you commit.**
  - **A. No conflict left.**
    - Run: `git diff --name-only --diff-filter=U` and `git grep -nE '^(<<<<<<<|>>>>>>>) '`.
    - Expected: both empty.
  - **B. No new Wine program names in app code.**
    - Run: `git grep -nE '"(wine64|wine|wineserver|wineloader|wineboot|winedevice)(\.exe)?"' -- 'Whisky/**/*.swift' 'WhiskyKit/Sources/**/*.swift' 'WhiskyCmd/**/*.swift'` on the merge result and on `main`, then diff the two outputs (strip line numbers).
    - Expected: no added lines. A new hit is changed to use `AnoWineRuntime` names.
  - **C. Identity and downloads.**
    - Run: `git grep -nE 'frankea\.github\.io|com\.franke' -- 'Whisky/**' 'WhiskyKit/Sources/**' 'WhiskyCmd/**' 'WhiskyThumbnail/**'`.
    - Expected: empty.
  - **D. Frozen feed untouched.**
    - Run: `git diff main -- dist/pages/WhiskyWineVersion.plist`.
    - Expected: empty.
  - **E. Every Wine launch carries the proxy.**
    - List the Swift files that start a Wine program: those referencing `AnoWineRuntime.loaderURL`, `AnoWineRuntime.serverURL` or `WhiskyWineInstaller.binFolder`, or calling `Wine.runProgram`, `Wine.runWineProcess`, `Wine.runWineserverProcess` or `Wine.runWine`. Compare the list with `main`.
    - Expected: every file new to the list goes through those `Wine` functions, or builds its environment with `Wine.constructWineEnvironment` plus `ProxyEnvironment.applying`. Name each one in the ledger with the existing test that covers it, or add a test in this task.
  - **F. Strings.**
    - Run: `python3 scripts/anowine/rebrand_strings.py --check Whisky/Localizable.xcstrings` and `grep -c $'\r' Whisky/Localizable.xcstrings`.
    - Expected: the check passes and the count is `0`.
- [ ] **Step 4: Commit and push**

```bash
git commit   # message: "Merge upstream Whisky app 3.10.2; Ano 8 reads the runtime 4.9.0 feed"
git push
```
Expected: every check is green on the merge commit:
- CI: SwiftFormat, SwiftLint, Localization, Build, Run Tests, UI tests, identity;
- AnoWine Hygiene;
- AnoWine Test Build.

Fix failures in follow-up commits under the rules above. Each fix goes in the ledger.

### Task 4: Steam detection counts programs started through ano-loader

**Files:**
- Modify: `WhiskyKit/Sources/WhiskyKit/Steam/SteamClientDriver.swift` (`windowsImageName(inCommand:)` and its doc comment)
- Test: `WhiskyKit/Tests/WhiskyKitTests/SteamClientOrchestratorProcessTests.swift`, `WhiskyKit/Tests/WhiskyKitTests/SteamLauncherTests.swift`

**Interfaces:**
- Consumes: the "Wine processes seen" listing from Task 1. It should show Windows programs whose command is `<…>/bin/ano-loader <image>`. If it shows no such line, record a ruling and still make this change; it costs nothing on 3.1.6.
- Signatures unchanged: `windowsImageName(inCommand: Substring) -> String?`, `steamPIDs(inProcessListing: String) -> Set<Int32>`.

- [ ] **Step 1: Write the failing tests.** Use the fixtures `wine`, `core` and a new `let loader = wine + "/bin/ano-loader"`.

```swift
@Test("On runtime 4.9.0 a program the app starts keeps the ano-loader path")
func exeNamesAfterTheLoaderLink() {
    let listing = """
    \(loader) C:\\Program Files (x86)\\Steam\\steam.exe -silent
    \(loader) start.exe /unix /Users/me/Games/game.exe
    \(core) C:\\windows\\system32\\services.exe
    \(wine)/bin/ano-server
    /bin/zsh -l
    """
    #expect(WineSteamClientDriver.exeImageNames(inProcessListing: listing)
        == ["steam.exe", "start.exe", "services.exe"])
}
```

In `SteamLauncherTests.steamPIDsAfterTheLoaderPath`, line `707 \(wine)/bin/ano-loader steam.exe` now counts: the expectation becomes `[303, 505, 707]`. Rename the test's display text to say both paths count.

- [ ] **Step 2: Push RED** (`test: Steam detection must count programs started through ano-loader`) and watch CI. Expected: Run Tests fails on these two tests only.
- [ ] **Step 3: Implement.** The image follows the first occurrence of `"/" + AnoWineRuntime.coreName + " "` or `"/" + AnoWineRuntime.loaderName + " "`. All other rules stay. Update the doc comment: runtimes up to 3.1.5 show the bare image path; 3.1.6 shows `ano-core`; 4.9.0 shows `ano-loader` for programs the app starts and `ano-core` for their children.
- [ ] **Step 4: Push GREEN** (`fix: count programs started through ano-loader as Windows processes`). Expected: CI green.

### Task 5: Point checks at the published engine; check both feeds

**Files:**
- Modify: `scripts/anowine/check-runtime-digest.sh`
- Create: `.github/workflows/AnoFeeds.yml`
- Modify: `.github/workflows/AnoWineRuntime.yml` (drop the `dist/pages/WhiskyWineVersion.plist` push path; the `digest` job calls the new script form)
- Modify: `.github/workflows/AnoProxy.yml` (`RUNTIME_URL`/`RUNTIME_SHA256` → v4.9.0; step name "Runtime (published)")
- Modify: `.github/workflows/AnoWineTraceScan.yml` (runtime → v4.9.0)

**Interfaces:**
- `check-runtime-digest.sh [repo-root]` checks every `dist/pages/WhiskyWineVersion*.plist`. For each passing feed it prints exactly `digest OK <file> v<version>`. It exits non-zero if any feed fails.

- [ ] **Step 1: Write the failing test.**
  - Create `AnoFeeds.yml`:
    - runs on `ubuntu-latest`;
    - triggers: push to `main` on paths `dist/pages/WhiskyWineVersion*.plist`, `scripts/anowine/check-runtime-digest.sh` and the workflow itself, plus `workflow_dispatch`;
    - one step: `bash scripts/anowine/check-runtime-digest.sh | tee out.txt`, then `grep -qx "digest OK WhiskyWineVersion.plist v3.1.6" out.txt && grep -qx "digest OK WhiskyWineVersion-v4.plist v4.9.0" out.txt`.
  - Push (`test: both runtime feeds must match their published assets`).
  - Expected: RED. The current script checks one feed and prints `digest OK`.
- [ ] **Step 2: Implement the loop in `check-runtime-digest.sh`, and switch AnoWineRuntime.yml's `digest` job to it.** Push. Expected: AnoFeeds green.
- [ ] **Step 3: Pin AnoProxy and the trace scan to v4.9.0.**
  - Push (`ci: proxy and trace-scan checks use runtime 4.9.0`).
  - Expected: Ano Proxy green, with the version printed as 4.9.0.
  - Dispatch `AnoWineTraceScan.yml`. Expected: green. Download the `wine-traces` artifact to the scratchpad and note its new items in the ledger; they are Plan 3c inventory.

### Task 6: Ano-8 test build, docs and handover

**Files:**
- Modify: `docs/anowine/TESTING-ON-M2.md` (new section "Ano-8: runtime 4.9.0")
- Modify: `README.md`, only where it names Ano's runtime version
- Workspace, outside the repo: `AnoWine/CLAUDE.md` Status, Names and Workflows table; memory `anowine-project.md`

- [ ] **Step 1: Build.** Take the latest green `AnoWine Test Build` run on HEAD; dispatch it if HEAD has none. Download the `Ano-test` artifact and rename it `Ano-8.zip`.
- [ ] **Step 2: Release.**
  - Run: `gh release create ano-test-8 --prerelease --title "Ano test build 8" --notes-file <notes> -R HighStormPVP/AnoWine Ano-8.zip`.
  - Use `ano-test-7`'s notes format, with:
    - built-from commit;
    - the install line with `Ano-8.zip`;
    - "Ano uses Wine runtime 4.9.0 (about 480 MB): Wine 11.19 with CrossOver's Mac patches, from upstream Whisky's engine 4.8.3, with Ano's names. Ano offers the update from 3.1.6 on launch; existing bottles update when first opened.";
    - "What's new": the new runtime (Steam's store, menus and popups draw; controllers; D3DMetal once Apple's Game Porting Toolkit is imported in Settings), upstream Whisky 3.8.0 to 3.10.2 (link to `https://github.com/frankea/Whisky/blob/main/CHANGELOG.md`), and the Steam detection fix from Task 4;
    - the same "Still true from Ano-6" list;
    - the SHA-256 of `Ano-8.zip`.
  - Expected: the release shows as Pre-release, and `v4.9.0` is unchanged.
- [ ] **Step 3: Docs.**
  - Add the owner's test list (Step 4) to `TESTING-ON-M2.md`.
  - Update CLAUDE.md:
    - Status: Plan 3a is done (Ano-8, runtime 4.9.0, which feed each app reads).
    - Names: the 4.9.0 layout, where `bin/ano-loader` is a link to `ano-core`.
    - Workflows table: add `AnoFeeds.yml`.
    - Next: the owner tests Ano-8, then Plan 3b.
  - Add a dated memory entry.
  - Commit with `[skip ci]` (docs only) and push.
- [ ] **Step 4: Hand over to the owner.** Give:
  - the release link;
  - the install line;
  - this test list, each item to report as pass or fail.

  1. Open Ano-8. It offers runtime 4.9.0; accept it. Settings then shows 4.9.0.
  2. Open your existing Steam bottle (proxy on, Hiddify running). Steam starts, signs in, and the store, menus and popups draw.
  3. Start a game download. It runs, and Hiddify shows Steam's connections.
  4. Start a game from Ano's Library. The tile shows it running, and closing the game clears that.
  5. Optional (D3DMetal): download Apple's Game Porting Toolkit (it needs an Apple developer sign-in), import it in Settings, set a DirectX 12 game's graphics to D3DMetal, and start it.
  6. Still open from before: run `m2-sandbox-check.sh`.

  Then ask whether Plan 3b (building the engine ourselves) comes next, or proxy Plan 2b or 2c. Recommend Plan 3b, as the design orders.
