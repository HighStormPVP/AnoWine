# Ano Plan 3c-3 — winetricks becomes ano-tricks

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `Libraries/ano-tricks` is winetricks 20260125 renamed by the owner's rule, with no update check, no stats report and its cache in Ano's cache folder; it is made by a script from the pinned upstream file, and the verbs the app uses work with it in a bottle of engine 5.0.0, which then passes the gate.

**Architecture:** `scripts/anowine/make-ano-tricks.sh` fetches upstream's `src/winetricks` at tag 20260125 (SHA-256 pinned), drops the verbs that download from third-party URLs named after Wine, renames the script with `rename_sources.py`'s rule (shared map plus a protect list for the script), applies small patches (`patches/tricks/`), and writes `Libraries/ano-tricks`. Hygiene regenerates it and fails if the committed file differs. The engine's check job (5.x) runs the app's verbs with it in the default bottle and gates the bottle. The app keeps calling `Libraries/winetricks` until Plan 3c-4 switches it (it ships with runtime 5.0.0).

**Tech Stack:** bash, Python 3 (`rename_sources.py`), the 3c-2 engine, GitHub Actions `ubuntu-latest` (Hygiene) and `macos-15` (check job).

**Spec:** `docs/superpowers/specs/2026-11-18-ano-full-rename-design.md`: decision 2 (the `winetricks` script → `ano-tricks`), How 3 (the same rename approach for winetricks) and How 7: "winetricks becomes `ano-tricks`: new variable names, its log `ano-tricks.log`, its cache in the app's cache folder (not `~/.cache/winetricks`), no upstream version check (today it calls raw.githubusercontent.com on every run, outside the bottle's proxy), no `W_PLATFORM=wine`."

## Global Constraints

- **Naming rule** as in 3c-1, with the shared `rename-map.txt`, which gains `winetricks` → `ano-tricks` (program). Names follow the engine's: `WINEPREFIX` → `ANOPREFIX`, `WINE` → `ANO`, `WINESERVER` → `ANOSERVER`, `Software\Wine` → `Software\Ano`, `wineboot` → `ano-boot`, `WINETRICKS_*` → `ANOTRICKS_*`, `winetricks.log` → `ano-tricks.log`.
- **Pin:** `https://raw.githubusercontent.com/Winetricks/winetricks/20260125/src/winetricks`, SHA-256 `431f82fc74000e6c864409f1d8fb495d696c03928808e3e8acffc45179312a7b` (the file Ano bundles today, minus Ano's one-line `ano-boot` edit, which the rule makes by itself).
- **Cache:** `${W_CACHE:-$HOME/Library/Caches/io.github.highstormpvp.Ano/ano-tricks}`.
- **Hosts:** a winehq.org URL becomes the repo URL (the shared map); a `github.com/Winetricks/winetricks` URL becomes the repo URL too (links only once the update check is gone). No URL may name a host Ano does not own with a renamed path.
- **Gate:** the generated script passes `wine_tokens.py --gate` with the allowlist's six categories; a bottle after the verbs passes it too.
- Scripts LF, mode 100755. `gh -R HighStormPVP/AnoWine`. RED pushed and watched before GREEN. 3c-3 ships nothing.

## Inventory (upstream 20260125)

19,866 lines, 1,813 mention Wine: variables (`WINE` 250, `WINEPREFIX` 137, `WINETRICKS_*`), functions (`winetricks_*`, `w_workaround_wine_bug`), registry paths, module names (`wined3d`, `winegstreamer`), `wine --version` parsing (`wine-` prefix), messages, URLs: 97 `bugs.winehq.org`, 10 `appdb`/`wiki.winehq.org`, 35 `github.com/Winetricks/winetricks` (links, `files/winetest.cat` for ie7/ie8, self-update), 2 `raw.githubusercontent.com/Winetricks/winetricks` (update check, self-update), 33 `github.com/iXit/wine-nine-standalone` (galliumnine02–07), 3 `codeberg.org/Synchro/powershell-wrapper-for-wine` (powershell), `kegel.com/data/winetricks-usage` (stats). Not Wine: AutoHotkey's `ifwinexist`/`IfWinExist`, `api-ms-win-rtcore-ntuser-winevent-l1-1-0`. The app uses: vcrun2022, vcrun2019, d3dcompiler_47, dotnet48, d3dx9, corefonts, xact, xinput, vcrun2013/2010/2008, mf, physx, dsound, cjkfonts, dotnetdesktop6, win32/win64.

## Review Focus

1. A renamed name ano-tricks writes that the engine reads under another name (a DLL override under `Software\Wine\DllOverrides`, `WINEDLLOVERRIDES`, a module name): the verb "succeeds" and changes nothing.
2. `wine --version` parsing: the engine prints `ano-11.19`; a check still expecting `wine-` would call the engine too old or unknown.
3. A download URL renamed by the rule (a file name or path on a host that is not winehq.org): the verb fails to download, or worse, fetches from a path someone else could claim.
4. The update check or stats report still reaching the network on every run.
5. A verb the app uses that breaks only under the renamed engine (an installer that checks `Software\Wine` itself).

---

### Task 1: `make-ano-tricks.sh` and the generated script

**Files:**
- Create: `scripts/anowine/make-ano-tricks.sh`, `scripts/anowine/rename-protect-tricks.txt`, `scripts/anowine/patches/tricks/*.patch`, `scripts/anowine/test-ano-tricks.sh`, `Libraries/ano-tricks`
- Modify: `scripts/anowine/rename-map.txt` (`winetricks` → `ano-tricks`), `scripts/anowine/wine-allowlist.txt`, `.github/workflows/AnoWineHygiene.yml`

**Interfaces:**
- Produces: `make-ano-tricks.sh [--check]`: downloads the pin (SHA-256 checked) to a temp folder, removes the verbs galliumnine02–07, galliumnine, ie7, ie8 and powershell (their `w_metadata` block and `load_` function), renames with `rename_sources.py --protect rename-protect-tricks.txt --map rename-map.txt` (the file alone, in a temp tree), applies `patches/tricks/*.patch`, and writes `Libraries/ano-tricks` (mode 755). `--check` writes to a temp file and exits 1 if it differs from the committed one. `test-ano-tricks.sh`: `bash Libraries/ano-tricks --version` prints `20260125`; `list-all` names vcrun2022 and not galliumnine; the update check, self-update and stats report do nothing (their functions return at once); the default cache is the Ano cache folder; the gate over the file passes.

- [ ] **Step 1: Tests first:** `test-ano-tricks.sh` and the Hygiene steps (`make-ano-tricks.sh --check`, `test-ano-tricks.sh`). Push `[skip ci]`, dispatch Hygiene. Expected: FAIL (no script, no `Libraries/ano-tricks`).
- [ ] **Step 2: Implement** the generator, the protect list, the patches (0001 no update check or self-update, 0002 cache folder, 0003 no stats report) and the allowlist entries the gate asks for (each read by hand; outside the six categories goes to the owner). Generate and commit `Libraries/ano-tricks`. Dispatch Hygiene. Expected: PASS.
- [ ] **Step 3: Commit** (`feat: ano-tricks, winetricks renamed`).

### Task 2: The app's verbs in a bottle

**Files:**
- Create: `scripts/anowine/check-ano-tricks.sh`
- Modify: `.github/workflows/AnoEngine.yml` (5.x check job)

**Interfaces:**
- Consumes: `Libraries/ano-tricks`, the 5.x engine (`engine_run`).
- Produces: `check-ano-tricks.sh <Libraries/Ano> <bottle>`: with `ANO`, `ANOSERVER`, `ANOPREFIX` exported and a persistent server (`ano-server -p60`), runs `ano-tricks -q vcrun2022 d3dcompiler_47 d3dx9 xact xinput` (a step timeout stops a hang); expects: each verb in the bottle's `ano-tricks.log`; `user.reg` has `Software\\Ano\\DllOverrides` with `d3dx9_43` native; `d3dcompiler_47.dll` in system32; the cache under `~/Library/Caches/io.github.highstormpvp.Ano/ano-tricks`; no `~/.cache/winetricks`; then the gate over the bottle.

- [ ] **Step 1: RED:** add the step calling `check-ano-tricks.sh` before the script exists. Dispatch `version=5.0.0` with `engine_run` set to 3c-2's green run. Expected: FAIL (no script).
- [ ] **Step 2: GREEN:** write `check-ano-tricks.sh`; dispatch the same. Expected: every expectation above holds; ledger the time per verb.
- [ ] **Step 3: Commit** (`test: the app's verbs work with ano-tricks on engine 5.x`).

### Task 3: Report

- [ ] **Step 1:** `spikes/REPORT.md` "## Plan 3c-3: ano-tricks": the pin, what was renamed, the verbs dropped and why, the patches, the allowlist entries added, the verb results and times, what 3c-4 must do (call `Libraries/ano-tricks` with `ANO`, `ANOSERVER`, `ANOPREFIX`, drop `Libraries/winetricks`). Update the workspace `CLAUDE.md`. Commit (`docs: Plan 3c-3 report`).
