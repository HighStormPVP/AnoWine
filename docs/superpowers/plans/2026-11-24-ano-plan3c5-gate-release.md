# Ano Plan 3c-5: the gate and the release

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship runtime 5.0.0 with the app that needs it (Ano 9, `ano-test-9`). Before that:
- the CI gate proves G1 ("no wine") on every runtime build and every app build, Mac state included;
- the hidden D3DMetal variables reach no helper program;
- the runtime carries the license texts of everything in it.

**Architecture:**
- **Engine work** (Tasks 1–2) ends in one Ano Engine build with version 5.0.0. That build is the release candidate.
- **The gate** (Tasks 3–4) has three parts:
  - The existing token scan (`wine_tokens.py`) stays the only judge.
  - `scan-wine-traces.sh` becomes a gate that captures Mac state while the engine (and, for app builds, the app) runs, and hands the captures to the token scan.
  - For the app bundle, Mach-O files are judged by their facts (signing identifier, entitlements, embedded Info.plist, load commands), not their raw bytes. Swift metadata names are code-only (decision 6), and the app's literals are already checked at the source (`check_app_text.py`, `check_app_runtime_names.py`).
- **The release** (Tasks 5–7):
  - publish that exact artifact as v5.0.0, after the owner's yes;
  - add its feed;
  - move the tests that still use 4.9.0 to 5.0.0;
  - release `ano-test-9`.

**Tech Stack:** bash, Python 3 (stdlib), C patches to the renamed engine source, GitHub Actions (`Ano Engine`, `AnoWine Test Build`, `AnoWine Hygiene`, `Ano Feeds`, `Ano Proxy`), `gh`.

**Spec:** `docs/superpowers/specs/2026-11-18-ano-full-rename-design.md`:
- G1, G2 and G3;
- Constraints;
- How 8 ("The gate");
- the anti-goal "A runtime that cannot be rebuilt from public source".

Roadmap: `docs/superpowers/plans/2026-11-19-ano-plan3c1-engine-rename.md`, row 3c-5.

Carried items:
- `.superpowers/sdd/2026-11-19-ano-plan3c1-engine-rename/progress.md`, lines 54, 84, 85, 87, 88 and 89;
- `…3c2…` line 89;
- `…3c4a…` lines 31 and 45;
- `…3c4c…` line 59.

## Global Constraints

- G1, verbatim: "No "wine" anywhere that Ano ships or creates, case-insensitive, wherever the letters mean Wine, except entries on a written allowlist the owner has approved."
- Allowlist categories, and only these: `not-wine`, `alias`, `apple`, `license`, `code-only`, `mono-internal`. "Anything else needs the owner's approval to be added." A new category, or an entry outside its category's meaning, is a question for the owner, not a ruling.
- The gate "scans the runtime archive (names and contents), the app bundle, and a bottle after creation, a program run, the Wine tools and winetricks verbs, plus the Mac state listed under G1. It runs on every runtime build and app build."
- "Publishing a runtime release needs the owner's yes each time. App test builds (`ano-test-N`) are pre-approved." Ask before anything else public: new repo settings, force-pushes.
- Feeds are served from raw.githubusercontent.com. Never from github.io, and never with insecure TLS (`curl -k`) in the app.
- The runtime is x86_64 under Rosetta; never build arm64 engine parts.
- Anti-goal, verbatim: "A runtime that cannot be rebuilt from public source. Wine is LGPL; the rename script, patches and build workflow stay in this repo, and release notes link to them."
- Only apps that read `dist/pages/AnoRuntimeVersion.plist` (Ano 9 and later) get 5.0.0. `WhiskyWineVersion.plist` (3.1.6) and `WhiskyWineVersion-v4.plist` (4.9.0) never change.
- Repo rules:
  - Test first (RED pushed and watched, then GREEN).
  - `[skip ci]` plus dispatched runs; stage files by path; `gh -R HighStormPVP/AnoWine`.
  - Scripts are LF, mode 100755.
  - Swift keeps the GPL header and SwiftLint `--strict`.
  - Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
  - Never widen a check or the allowlist just to pass.

## Review Focus

1. **The owner installs Ano 9.** The setup flow reads `AnoRuntimeVersion.plist` and downloads `v5.0.0/Libraries.tar.gz`, and the digest matches. A wrong digest blocks every first install. Test: Task 5, `Ano Feeds` expects `digest OK AnoRuntimeVersion.plist v5.0.0`.
2. **A helper program the engine starts gets `WINED3DMETAL` or `WINEESYNC`** through a spawn call nobody listed. Test: Task 1, the spawn-site scan fails the engine build on any unlisted or unhandled site. Its fixtures cover `fork`+`execl`, `posix_spawn`, `posix_spawnp`, `system` and `popen`.
3. **The gate fails or passes for the wrong reason.**
   - Failing wrongly: on harness noise, such as the checkout path `…/AnoWine/AnoWine`, or Swift metadata in the app.
   - Passing wrongly: because a capture is empty.
   - Test: Task 3, the planted-trace self-test must fail with exactly the planted tokens, and Task 4's `--skip-macho` test.
4. **A dylib added to the engine later ships without its license.** Test: Task 2, `test-check-licenses.sh`, where an unlisted dylib fails.
5. **The owner goes back to Ano 8 after trying Ano 9.** Ano 8 must still work on its own runtime (4.9.0) and its bottles. The imported GPTK store has been renamed to `lib/ano`, so Ano 8 needs to import it again. Test: none can run in CI. Task 7's release notes and test notes say so.

---

### Task 1: The spawn-site scan, and the alias leak in printing and NTLM

`patches/rename/0005` sets `WINED3DMETAL` and `WINEESYNC` inside each process and drops them from the children ntdll starts. Four more spawn sites pass the live environment on:
- `dlls/localspl/cups.c`: `fork` + `execl("/bin/sh")` (about line 178), and `posix_spawn(..., *_NSGetEnviron())` (about lines 275 and 328);
- `dlls/msv1_0/unixlib.c`: `posix_spawnp(..., environ)` in `ntlm_fork` (about line 200).

Line numbers are at winecx `9f3f644`, before the rename.

**Files:**
- Create:
  - `scripts/anowine/spawn_sites.py` and `scripts/anowine/test_spawn_sites.py` (fixtures in `scripts/anowine/tests/spawn/`);
  - `scripts/anowine/spawn-sites.txt`;
  - `scripts/anowine/patches/rename/0006-ano-env-aliases-helpers.patch`.
- Modify:
  - `scripts/anowine/build-engine.sh`: run the scan right after the rename patches apply, and stop the build on exit 1;
  - `.github/workflows/AnoWineHygiene.yml`: run the new test.

**Interfaces:**
- **Produces** `spawn_sites.py SRC --sites FILE`:
  - exit 0 when every site is listed and handled;
  - exit 1 otherwise, printing `unlisted <path> <function> <call>` or `unhandled <path> <function> <call>`;
  - exit 2 on bad input.
- **A site** is a call, after C comments and strings are blanked, to one of `execl execle execlp execv execve execvp execvpe fexecve posix_spawn posix_spawnp system popen`, in a `.c` or `.m` file under the source root. `tools/` and `*/tests/*` are excluded.
- **Its key** is `(path relative to SRC, enclosing function name, call)`, not a line number, so it survives upstream line changes.
- **`spawn-sites.txt`** has one line per site: `path<TAB>function<TAB>call<TAB>handling<TAB>reason`. `handling` is one of:
  - `drops-aliases`: the enclosing function's body calls `ano_env_without_aliases(` or `ano_env_unset_aliases(`; the scanner checks this;
  - `before-aliases`: the site runs before `ano_env_set_aliases`, such as the loader's re-exec;
  - `not-a-spawn`: a definition, or PE-side code such as msvcrt's own `system`.
- **The patch** exports `ano_env_without_aliases` and `ano_env_unset_aliases` from ntdll.so to other unix libraries. They are declared in the renamed unixlib header, the same way ntdll.so already exports `ntdll_umbstowcs` to them.

- [ ] **Step 1: Write the failing tests** in `test_spawn_sites.py`:
  - `test_an_unlisted_site_fails`: a fixture with `posix_spawnp(..., environ)` in `ntlm_fork` and an empty list. Exit 1, and the output contains `unlisted dlls/msv1_0/unixlib.c ntlm_fork posix_spawnp`.
  - `test_a_drops_aliases_site_without_the_helper_fails`: the same site, listed as `drops-aliases`, but its function never calls a helper. Exit 1, `unhandled`.
  - `test_a_handled_site_passes`: the function calls `ano_env_without_aliases()`. Exit 0.
  - `test_every_call_form_is_found`: one fixture holds `fork`+`execl`, `posix_spawn`, `posix_spawnp`, `system` and `popen`. All five are reported as unlisted.
  - `test_comments_strings_and_prefixed_names_are_not_sites`: `/* execv( */`, `"system("` and `_execv(` give no site.

  Push with `[skip ci]` and dispatch Hygiene. Expected: the new test step fails, because the module is missing.
- [ ] **Step 2:**
  - Implement `spawn_sites.py`.
  - Wire it into `build-engine.sh`, then dispatch `Ano Engine` with `version` `5.0.0`. Expected: the build stops at the scan and lists the four sites above, among others. Copy the full list into the ledger.
  - Write `spawn-sites.txt`: every site with its handling and a one-line reason. The sites patch 0005 already handles are `drops-aliases`.
- [ ] **Step 3:** Write patch 0006. `cups.c`'s forked child calls `ano_env_unset_aliases()` before `execl`. Its two `posix_spawn` calls and `ntlm_fork`'s `posix_spawnp` pass `ano_env_without_aliases()` and free the copy afterwards (`if (env != environ) free(env)`). Each call carries a comment naming patch 0006. Run `test_spawn_sites.py` in Hygiene: green.
- [ ] **Step 4:** Do not build yet. Task 2's build is the GREEN for both tasks: the scan passes inside it, and the engine check stays green. Ledger the list of sites.

### Task 2: License texts in the runtime

Today `share/ano/NOTICES` names the LGPL but has no license text, and MoltenVK is renamed in place without its notice. A carried ruling makes this a release blocker.

**Files:**
- Create:
  - `scripts/anowine/licenses.txt` (the manifest);
  - `scripts/anowine/check-licenses.sh` and `scripts/anowine/test-check-licenses.sh` (fixture trees made by the test itself).
- Modify:
  - `scripts/anowine/build-engine.sh`: a `write_licenses` step; NOTICES lists every component;
  - `.github/workflows/AnoEngine.yml`: a check step "License texts" for 5.x;
  - `.github/workflows/AnoWineHygiene.yml`: run the new test.

**Interfaces:**
- **The manifest** has one line per component: `component<TAB>version<TAB>spdx<TAB>source<TAB>license-files<TAB>covers<TAB>modified`.
  - `source`: `winecx`, `nix:<nixpkgs attribute>`, `url:<pinned URL already in build-engine.sh>` or `payload:<folder>`.
  - `license-files`: comma-separated paths inside that source.
  - `covers`: comma-separated globs relative to `Libraries/`.
  - `modified`: `no`, or a short statement of what Ano changed (`renamed files and strings`).
- **License files** are the component's own texts, taken from its source: `COPYING.LIB` from winecx for the engine, MoltenVK's `LICENSE` and `NOTICE`, DXVK's and DXMT's `LICENSE`, mono's license files, and each nixpkgs library's own `COPYING`/`LICENSE`. They are never generic templates.
- **Where they go:** `write_licenses` copies them to `Libraries/Ano/share/ano/licenses/<component>/`.
- **NOTICES** gains a table: component, version, license, where its source is, and what Ano changed. Apache-2.0 §4(b) and zlib's "altered versions must be plainly marked" are met by the `modified` column.
- **`check-licenses.sh <Libraries>`** exits 1, naming the cause, when:
  - a component has no non-empty license file in the runtime;
  - NOTICES lacks a component;
  - a regular file under `Libraries/` matches no component's globs.

  Components match in manifest order, and the first match wins. The engine's globs are `Ano/bin/*`, `Ano/lib/ano/**`, `Ano/share/ano/**` and `AnoRuntimeVersion.plist`. Third-party dylibs in `Ano/lib/` are listed one family per component, so a new dylib with no entry fails the check.

- [ ] **Step 1: Write the failing tests.**
  - In `test-check-licenses.sh`:
    - a complete fixture passes;
    - an extra `Ano/lib/libnew.1.dylib` fails, naming it;
    - an empty license file fails;
    - a NOTICES without one component fails.
  - Add a check step that runs `check-licenses.sh` on the current engine artifact (`engine_run` = the newest 5.x Ano Engine run whose `ano-engine` artifact has not expired; ledger the id).
  - Push and dispatch Hygiene and that check. Expected: both fail. Hygiene fails because the script is missing; the check fails because there is no licenses folder.
- [ ] **Step 2:** Write the manifest from the artifact's real file list: `find Libraries -type f`, plus the dylibs in `Ano/lib`. Take each nixpkgs library's SPDX id from `nix eval --raw <attr>.meta.license.spdxId` at the pinned `NIXPKGS_REV`, and its license file from its source (`nix build --print-out-paths <attr>.src`). Implement `write_licenses` and `check-licenses.sh`.
- [ ] **Step 3: Build the release candidate.** Dispatch `Ano Engine` with `version` `5.0.0`.

  Expected:
  - the build passes Task 1's scan;
  - the check job is green on every step, including "License texts" and the gate (`wine_tokens.py --gate` over Libraries and both bottles: license texts carry no "wine" except allowlisted phrases).

  Ledger this run id as **the release candidate**. Tasks 3, 4, 5 and 7 use exactly this artifact.

### Task 3: The Mac-state gate on every runtime build

**Files:**
- Rewrite `scripts/anowine/scan-wine-traces.sh` for engine 5.x only.
- Modify `.github/workflows/AnoEngine.yml`: steps for 5.x.
- Delete `.github/workflows/AnoWineTraceScan.yml`, the report-only 4.x workflow. The gate replaces it.

**Interfaces:**
- **Usage:** `scan-wine-traces.sh <Libraries> <ano-tricks> <report-dir> [--app <Ano.app>] [--plant]`.
  - Exit 0: the gate passes.
  - Exit 1: a token not on the allowlist. `<report-dir>/traces.md` lists the tokens and where each was seen.
  - Exit 2: a harness error, such as an empty capture where one cannot be empty, or a step that never started.
- **What it runs** with a persistent server (`ano-server -p60`):
  - creates a bottle (`ano-boot --init`);
  - runs a console program (`cmd /c set`, which gives the Windows environment);
  - opens the engine's GUI tools for a few seconds each (`ano-cfg`, `regedit`, `notepad`);
  - runs one ano-tricks verb (`win10`).
  - It runs the test programs and ano-tricks from copies in its work folder under `/private/tmp`, so no captured path carries the checkout path.
- **What it captures:** only what is new since the start, as text files in `<report-dir>/gate/`.
  - Command lines and environments of the processes whose command contains `/Libraries/Ano/` or the work folder, or whose name starts with `ano-`.
  - The Windows environment.
  - Open files (`lsof -c ano-`).
  - Files created or changed under `HOME`, the temporary folder, the user cache folder and `/private/tmp`, outside the bottle. They are copied into `gate/outside/` keeping their relative paths, up to 5 MB each; larger files are listed by name.
  - New defaults domains with their contents.
  - New lines in `launchctl list`, `launchctl print gui/<uid>`, `lsappinfo list` and the LaunchServices dump.
  - New files in the Rosetta cache (`sudo -n find /private/var/db/oah -newer <start marker>`), by name.
  - The system log since the start (`log show --start`), from processes whose name starts with `ano-` plus every line that contains "wine".
- **The judge:** `wine_tokens.py <report-dir>/gate <bottle> --allowlist scripts/anowine/wine-allowlist.txt --out <report-dir>/tokens.tsv --gate`.
- **`--plant`** (the self-test):
  - during the run, starts a console program through `ano-loader` with `PLANTWINE=1` in its environment;
  - creates `~/.cache/plantwine/x`;
  - writes a log line with `logger "plantwine"`.

  The gate must then exit 1 and list exactly `PLANTWINE`, `plantwine` (the folder and the log line). Anything else, or a missing token, exits 2.

- [ ] **Step 1: Add the failing steps** to the 5.x engine check:
  - "The gate sees planted traces": runs `--plant` and expects exit 1 with exactly those tokens;
  - "Mac state gate": runs it without `--plant` and expects exit 0.

  Push and dispatch the check with `engine_run` = the release candidate. Expected: both fail, because the old script reads `Libraries/Wine` (exit 2).
- [ ] **Step 2:** Rewrite the script. Re-dispatch. Expected:
  - the planted run finds its three tokens;
  - the real run passes, or lists real findings.

  For each finding: fix it in the engine (a new rename patch and a rebuild, then re-ledger the release candidate) or put it on the allowlist under an existing category with its reason. A finding no category fits stops the task and goes to the owner.
- [ ] **Step 3: Compare the two boot warnings with upstream.** Add a report-only step that boots a bottle on upstream's v4.8.3 (`frankea/Whisky` v4.8.3 `Libraries.tar.gz`, SHA-256 as `AnoWineRuntime.yml` pins it, with its own `WINE*` variables). It prints whether the boot log shows the Bluetooth driver failing (`c00000e5`) and `error loading cxcompatdb.so`, as 5.x does. Record the answer in the ledger.
- [ ] **Step 4:** Delete `AnoWineTraceScan.yml`. Commit and ledger.

### Task 4: The gate on every app build

**Files:**
- Create `scripts/anowine/macho_facts.sh`.
- Modify:
  - `scripts/anowine/wine_tokens.py` and `scripts/anowine/test_wine_tokens.py`: `--skip-macho`;
  - `.github/workflows/AnoWineTestBuild.yml`: input `engine_run`, and two gate steps;
  - `scripts/anowine/wine-allowlist.txt`: entries the app's run needs, existing categories only.

**Interfaces:**
- **`wine_tokens.py --skip-macho`:** a file whose first four bytes are a Mach-O or fat magic (`feedface`, `feedfacf`, `cafebabe`, either byte order) contributes its name only, never its contents.
- **`macho_facts.sh <Ano.app> <out-dir>`** writes one text file per Mach-O in the bundle, holding:
  - `codesign -dv` (Identifier line);
  - `codesign -d --entitlements :-`;
  - `otool -L`;
  - the `LC_RPATH` and `LC_ID_DYLIB` entries of `otool -l`;
  - the embedded `__TEXT,__info_plist`.

  The out file's name is the Mach-O's path with `/` replaced by `__`.
- **The app-bundle gate:** `wine_tokens.py <Ano.app> <facts> --skip-macho --allowlist … --gate`.
- **The app's Mac-state gate:** `scan-wine-traces.sh <Libraries> <Ano.app>/Contents/Resources/ano-tricks <report> --app <Ano.app>`. With `--app` it also:
  - puts `<Libraries>` where the app keeps its runtime;
  - opens the app for 60 seconds and quits it (`osascript -e 'quit app "Ano"'`);
  - creates a bottle and runs a program with the bundled CLI, as `check-app-on-engine.sh` does.
- **`engine_run`** (an Ano Engine run id) chooses the runtime for the app's gate. When it is empty, the runtime named by `dist/pages/AnoRuntimeVersion.plist` is downloaded and its SHA-256 checked. With neither, the step fails and says why.

- [ ] **Step 1: Write the failing tests.**
  - In `test_wine_tokens.py`:
    - `test_skip_macho_scans_the_name_only`: a file starting `cf fa ed fe` holding `WhiskyWineInstaller`, named `plainwine`. Only `plainwine` is reported.
    - `test_skip_macho_reads_other_files`: a text file with `WINEPREFIX` next to it is still reported.
  - Add both gate steps to `AnoWineTestBuild.yml`.
  - Push. Dispatch Hygiene, and the test build with `engine_run` = the release candidate. Expected: Hygiene fails on the two tests; the build fails because `macho_facts.sh` is missing.
- [ ] **Step 2:** Implement `--skip-macho`, `macho_facts.sh` and `--app`, then re-dispatch.
  - Expected: Hygiene green, and the test build green on every step.
  - Findings follow Task 3 Step 2's rule. A "wine" token in a user-visible app file is a bug to fix (`check_app_text.py` should have caught it: add the missing case to its tests), never an allowlist entry.

### Task 5: Runtime 5.0.0 and its feed (the owner's yes)

**Files:**
- Modify:
  - `.github/workflows/AnoEngine.yml`: input `publish` (boolean, default false), and a `publish` job;
  - `scripts/anowine/check-runtime-digest.sh`: also read `dist/pages/AnoRuntimeVersion.plist`;
  - `.github/workflows/AnoFeeds.yml`: expect it, and add it to the `paths`.
- Create:
  - `docs/anowine/runtime-5.0.0-notes.md` (the release notes);
  - `dist/pages/AnoRuntimeVersion.plist`.

**Interfaces:**
- **The `publish` job** runs only when `publish` is true, the version does not start with `4.`, and the check job succeeded. It downloads the `ano-engine` artifact of `engine_run` (or this run), checks `Libraries.tar.gz.sha256`, and runs `gh release create v<version> Libraries.tar.gz --title "Ano runtime <version>" --notes-file docs/anowine/runtime-<version>-notes.md`. It is not a pre-release: runtime releases are "Latest", and app builds stay pre-releases.
- **The notes:**
  - what 5.0.0 is: the engine of runtime 4.9.0 (winecx `9f3f644`, Wine 11.19 with CrossOver's patches), built by this repo and renamed;
  - that it is for Ano 9 and later, and that earlier apps stay on 4.9.0 or 3.1.6;
  - that bottles from earlier runtimes must be made again;
  - the license (LGPL-2.1; the texts are in `share/ano/licenses`);
  - links to the repo, `scripts/anowine/build-engine.sh`, `scripts/anowine/rename_sources.py`, `scripts/anowine/patches/rename/` and the Ano Engine run that built it.
- **The feed** has the same keys as `WhiskyWineVersion-v4.plist`:
  - `dxmtVersion`, `dxvkVersion` and `gptkCapable`, copied from the archive's `Libraries/AnoRuntimeVersion.plist`;
  - `sha256` of the published asset;
  - `version` 5.0.0.

- [ ] **Step 1 (RED):**
  - Change `check-runtime-digest.sh`'s feed list to `WhiskyWineVersion*.plist` plus `AnoRuntimeVersion.plist`.
  - Make `AnoFeeds.yml` also require `digest OK AnoRuntimeVersion.plist v5.0.0`.
  - Push and dispatch `Ano Feeds`. Expected: it fails, because there is no feed and no release.
- [ ] **Step 2:** Write the notes and the `publish` job. Push with `[skip ci]`.
- [ ] **Step 3: STOP. Ask the owner, in one message:**
  - **Publish runtime 5.0.0** from the release candidate? Recommend yes: only Ano 9 reads its feed, and Ano 9 is a test build.
  - **The D3DMetal listing.** If `ano-gptk-wine-names.txt` has not arrived, ask for it, or for the owner's choice to let Ano 9's D3DMetal game test decide instead. Recommend the game test, since the aliases are provisional either way. (The 3c-1 ledger ruling made the listing a requirement before 3c-5; the owner's answer replaces it.)

  Wait for the answer. Do nothing public before it.
- [ ] **Step 4:** On yes, dispatch `Ano Engine` with `version` `5.0.0`, `engine_run` = the release candidate and `publish` true. Expected: the check job is green again, and release v5.0.0 has the asset.
- [ ] **Step 5 (GREEN):** Write the feed from the archive's plist and the asset's digest. Push it, and dispatch `Ano Feeds`. Expected: `digest OK AnoRuntimeVersion.plist v5.0.0` (and the two older lines).

### Task 6: The tests move to 5.0.0

**Files:**
- `.github/workflows/AnoProxy.yml`: `RUNTIME_URL`/`RUNTIME_SHA256` become v5.0.0;
- `scripts/anowine/check-proxy.sh`: drop the `Libraries/Wine` (4.x) branch. The ledger ruling of 3c-4a, line 31, said to remove it after 5.0.0 ships.

- [ ] **Step 1:** Change the workflow's runtime, and make `check-proxy.sh` fail with a clear message on a `Libraries/Wine` layout. Push and dispatch `Ano Proxy` with no inputs. Expected: green on the published 5.0.0. A run with an old 4.x `runtime_run_id` fails with that message.
- [ ] **Step 2:** Commit and ledger.

### Task 7: Ano 9 (`ano-test-9`)

**Files:**
- `docs/anowine/TESTING-ON-M2.md`: the section "Ano 9", next to the existing "Ano 9: clean old traces";
- the release (pre-approved).

- [ ] **Step 1:** Dispatch `AnoWine Test Build` on main with `engine_run` empty, so the app's gate runs on the published runtime from the feed. Expected: green on every step.
- [ ] **Step 2: Write the test notes.** Each item says what to do and what to send back.
  1. Install Ano 9 and let it download runtime 5.0.0.
  2. The old bottles are listed as old, refused, and left unchanged.
  3. Make a new bottle, then Steam: install, log in, store, download, launch a game. The risk to watch is Steam or anti-cheat looking for `wine_get_version`.
  4. A D3DMetal game with the toolkit imported in Ano 8, with no new import (the store was renamed).
  5. A DXVK game, 32-bit if the owner has one. 32-bit DXVK crashes on the CI runner, as the prebuilt one does.
  6. The proxy.
  7. If runtime update checks were turned off in Ano 8, Settings still shows them off.
  8. Run `clean-rosetta-cache.sh`, first without and then with `--delete`, and send its output.
  9. Activity Monitor and `ps` show no "wine". `~/.cache/winetricks` is gone unless Homebrew winetricks or the original Whisky is installed.
  10. `ano-gptk-wine-names.txt`, if not sent yet.
- [ ] **Step 3: Release.** Download the `Ano-test` artifact and rename it `Ano-9.zip`. Create pre-release `ano-test-9` with `Ano-9.zip`, `clean-rosetta-cache.sh` and `list-gptk-wine-names.sh`. The notes follow `ano-test-6`'s format (install line, what's new, watch for, still true from Ano-6, SHA-256), and say:
  - Ano 9 needs runtime 5.0.0 and downloads it on first launch.
  - Old bottles stay untouched but cannot be opened: make new ones.
  - The first launch removes old traces once.
  - One `sudo` script handles Rosetta's cache.
  - Going back to Ano 8: quit Ano, delete `~/Library/Application Support/io.github.highstormpvp.Ano/Libraries`, install Ano 8 (it downloads 4.9.0), and import the Game Porting Toolkit again.
  - The proxy's limits are still true from Ano 6.
- [ ] **Step 4:** Give the owner the install line with `Ano-9.zip`.

### Task 8: Report

- [ ] Add `spikes/REPORT.md` "## Plan 3c-5: the gate and the release", covering:
  - what the gate covers and where it runs;
  - the spawn sites and how each is handled;
  - the license manifest;
  - the upstream comparison of the two boot warnings;
  - the release, the feed, and Ano 9.
- [ ] Update the workspace `CLAUDE.md`:
  - status;
  - the workflow table: Trace Scan removed; Ano Engine's `publish`; the Test Build's gate and `engine_run`.
- [ ] Commit.

Next, queued by the owner: the CI test of the Windows Opera GX through a test SOCKS5 proxy.
