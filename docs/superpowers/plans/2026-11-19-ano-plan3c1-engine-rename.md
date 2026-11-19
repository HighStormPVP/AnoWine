# Ano Plan 3c-1 — the engine without "wine"

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `build-engine.sh` builds engine 5.0.0: Wine 11.19 + CrossOver (the tree Plan 3b reproduced) renamed by a script, so that the engine's Wine parts and a new bottle made with it contain no "wine" token except entries on the allowlist.

**Architecture:** A Python script, `rename_sources.py`, rewrites the pristine Wine tree after the patches and before configure: path names and the contents of every text file, by the owner's naming rule, with a protect list (Windows API names and English words that only contain the letters) and a fixed map (programs, reverse-DNS identities, URLs). Because the rule is uniform, generated files (`configure`, `Makefile.in` lists) stay consistent and need no regeneration. A small patch set applied after the rename names the loader `ano-core` and adds the hidden aliases closed parts need. `build-engine.sh` gets a rename mode (engine version 5 or later) with Ano's layout (`Libraries/Ano`, `lib/ano`, `share/ano`). `wine_tokens.py` gets a `--gate` mode, and `Ano Engine` runs it over the engine and a new bottle.

**Tech Stack:** Python 3 (stdlib; `fontTools` pinned for font name tables, installed in the build job only), bash, the Plan 3b build (Xcode 16.4, Homebrew mingw-w64 gcc, Nix-pinned libraries), GitHub Actions `macos-15` and `ubuntu-latest`.

**Spec:** `docs/superpowers/specs/2026-11-18-ano-full-rename-design.md`: decisions 1, 2, 4, the two further rules, G1, G3, "What counts", How 3, 4, 5 and 8. Plan 3b's ledger findings: `winecx` is baked into 1033 files through relative `__FILE__` paths; `lsteamclient.so` bakes the absolute build folder.

## Plan 3c roadmap

The design's Plan 3c is five plans, each with its own document, run in this order:

| Plan | Scope | Ships |
|---|---|---|
| **3c-1 (this)** | Wine's own source renamed; engine 5.0.0 layout; the gate over engine and bottle | nothing |
| 3c-2 | DXVK and DXMT rebuilt from source against the renamed engine; wine-mono renamed (names only, plus its Wine imports); Gecko dropped | nothing |
| 3c-3 | winetricks → `ano-tricks` | nothing |
| 3c-4 | the app: every item of the design's app list, the new feed `AnoRuntimeVersion.plist`, old-bottle detection, GPTK import into the renamed folders, first-launch cleanup and the owner's admin script | nothing |
| 3c-5 | the gate in CI on every runtime and app build (Mac state included), runtime 5.0.0 (owner's yes) and `ano-test-N` | runtime 5.0.0, app |

## Global Constraints

- **Naming rule** (decision 2), case-sensitive, applied in this order:
  1. Protected text stays as it is (`scripts/anowine/rename-protect.txt`): Windows names that only contain the letters, matched anywhere inside a token (`winerror`, `Winerror`, `WINERROR` — `winerror.h` alone is included 39,822 times —, `winevt`, `WINEVT`, `winefs`, `winevent`, `WINEVENT`, `WINEXEC`, `winexe`), and plain words matched as whole words (`twine`, `swine`, `intertwine`, `intertwined`).
  2. Fixed map (`scripts/anowine/rename-map.txt`, `old<TAB>new`, longest first):
     - programs that run as processes get `ano-` plus the rest of the old name, as whole words (not next to `[A-Za-z0-9_]`): `wineboot`→`ano-boot`, `winebrowser`→`ano-browser`, `winecfg`→`ano-cfg`, `wineconsole`→`ano-console`, `winedbg`→`ano-dbg`, `winedevice`→`ano-device`, `winefile`→`ano-file`, `winemenubuilder`→`ano-menubuilder`, `winemine`→`ano-mine`, `winemsibuilder`→`ano-msibuilder`, `winepath`→`ano-path`, `wineserver`→`ano-server`, `winevdm`→`ano-vdm`;
     - reverse-DNS identities: `org.winehq.wine`→`io.github.highstormpvp.Ano.core`, then `org.winehq.`→`io.github.highstormpvp.Ano.`;
     - URLs: a whole URL on `bugs.winehq.org` → `https://github.com/HighStormPVP/AnoWine/issues`; a whole URL on any other `winehq.org` host, or a bare `winehq.org`, → `https://github.com/HighStormPVP/AnoWine` (the path is dropped). No output may name a host Ano does not control: `anohq` must not appear anywhere after the rename.
  3. Everything else: `wine`→`ano`, `Wine`→`Ano`, `WINE`→`ANO`.
- **License notices stay word for word** (design, "further rules"): the phrases in `rename-protect.txt` marked `license` (Wine's LGPL copyright line in version resources, for example `the Wine project authors`) are not renamed; the gate allows them only as whole phrases.
- **Folders without "wine"**: work folder `$RUNNER_TEMP/ano-engine`, source folder `ano-src` (was `winecx`), install prefix `/opt/ano` (was `/opt/whiskywine`). They are baked into binaries.
- **Engine 5.x layout** (How 5): `Libraries/Ano/bin/ano-loader` → `../lib/ano/x86_64-unix/ano-core`, `Libraries/Ano/bin/ano-server`, `Libraries/Ano/lib/ano/{i386-windows,x86_64-windows,x86_64-unix}`, `Libraries/Ano/share/ano/`, `Libraries/AnoRuntimeVersion.plist` (same keys as `WhiskyWineVersion.plist`). No `wine`, `wine64`, `wineloader` links; no man pages; no `share/applications`. The loader's identity: name `Ano`, identifier `io.github.highstormpvp.Ano.core`, principal class `AnoApplication`.
- **3c-1 builds Wine's own parts only.** DXVK, DXMT and wine-mono come back in 3c-2 (rebuilt or renamed); Gecko is dropped. MoltenVK, SDL2, gstreamer and the Nix libraries stay as in 3b.
- **Aliases** (decision 4): only for closed parts, only as strings inside our binaries, each listed in `scripts/anowine/aliases.txt` (`old<TAB>new<TAB>where<TAB>closed part<TAB>how confirmed`). Until the owner's `ano-gptk-wine-names.txt` arrives, the D3DMetal entries are marked `provisional`.
- **Repeatable** (G3): the rename runs on a fresh clone every build; the same input gives the same tree (the test checks a second run changes nothing).
- **3b stays reproducible**: `ANO_ENGINE_VERSION=4.8.3` builds exactly as in Plan 3b (no rename, upstream's folder), and `Ano Engine` keeps its 4.8.3 comparison.
- Never build arm64 Wine parts. Scripts LF and mode 100755. `gh -R HighStormPVP/AnoWine`. RED pushed and watched before GREEN. Plan 3c-1 ships nothing.

## Review Focus

1. A protected or mapped word that the general rule still reaches through a longer token (`HWINEVENTHOOK` inside `pHWINEVENTHOOK`), or a program-map entry that lands inside a C identifier (`winedbg_main` must become `anodbg_main`, not `ano-dbg_main`).
2. A generated file the rename leaves inconsistent with its source (`configure` against `configure.ac`, `.spec` against exports, `server/request.h` against `protocol.def`), which builds but fails at run time.
3. Binary files in the tree that carry "wine" (fonts, `.nls`, icons, test data) and slip past a text-only rename.
4. A URL rewritten to a host Ano does not own (`anohq.org`), which would let a stranger serve downloads to bottles.
5. A closed part (D3DMetal) that needs an old name the provisional alias list misses: it fails only on the owner's Mac.

---

### Task 1: `rename_sources.py`, the rename of a source tree

**Files:**
- Create: `scripts/anowine/rename_sources.py` (755), `scripts/anowine/test_rename_sources.py`, `scripts/anowine/rename-protect.txt`, `scripts/anowine/rename-map.txt`

**Interfaces:**
- Produces: `rename_sources.py SRC --protect FILE --map FILE [--report FILE]`, exit 0, or 1 when a rule conflicts (two paths renamed to one, a protected word that does not occur). Functions: `rename_text(text: str, rules: Rules) -> str`, `rename_path(rel: str, rules: Rules) -> str`, `load_rules(protect: Path, map: Path) -> Rules`, `rename_tree(src: Path, rules: Rules) -> Report` (counts of renamed paths and changed files; binary files with "wine" listed by path).
- `rename-protect.txt`: `text<TAB>kind<TAB>reason`, kind `substring` (Windows names, matched inside tokens), `word` (whole words) or `license` (whole phrases). `rename-map.txt`: `old<TAB>new<TAB>kind`, kind `program`, `identity` or `url`.

- [ ] **Step 1: Build the protect list from the source.** Scan the Wine tree (Plan 3b's pinned commit) for case-sensitive `wine|Wine|WINE` inside identifiers and words. Keep for `rename-protect.txt` the Windows API names (declared in `include/*.h` outside `include/wine/`, such as `WINEVENT_*`, `WINEVENTPROC`, `HWINEVENTHOOK`, `CREATEPROCESSFROMWINEXEC`) and English words (`intertwine`, `intertwined`, `twine`, `swine`). Everything Wine names after itself (`IWine*`, `PWINE_*`, `tagWINE_*`, `wgl*WINE`) is renamed. Add the license phrases (`the Wine project authors` and any other copyright line found in `include/wine/wine_common_ver.rc` and the version resources). Ledger the counts.
- [ ] **Step 2: Write the failing tests** in `test_rename_sources.py`:
  - `test_case_rule`: `"wine Wine WINE"` → `"ano Ano ANO"`; `"WinExec WinEvent"` unchanged.
  - `test_protected`: `"WINEVENT_OUTOFCONTEXT HWINEVENTHOOK intertwined #include \"winerror.h\" winevt.h winefs.h"` unchanged; `__WINE_WINERROR_H` → `__ANO_WINERROR_H`; `testwine` → `testano` (whole-word entries do not match inside tokens); `"the Wine project authors"` unchanged; `"Wine project"` alone → `"Ano project"`.
  - `test_programs`: `"winecfg.exe"` → `"ano-cfg.exe"`; `"programs/winedbg/"` → `"programs/ano-dbg/"`; `winedbg_main` → `anodbg_main`; `WINEDBG` → `ANODBG`.
  - `test_identity_and_urls`: `org.winehq.wine` → `io.github.highstormpvp.Ano.core`; `org.winehq.builtin.text` → `io.github.highstormpvp.Ano.builtin.text`; `https://bugs.winehq.org/show_bug.cgi?id=1` → `https://github.com/HighStormPVP/AnoWine/issues` (the rest of the URL is dropped); `https://dl.winehq.org/wine/wine-mono/` → `https://github.com/HighStormPVP/AnoWine`; no output contains `anohq`.
  - `test_tree`: a temp tree with `dlls/winemac.drv/cocoa_window.m` ("WineWindow"), `programs/winecfg/Makefile.in` (`MODULE = winecfg.exe`), `include/wine/debug.h`, a binary file `fonts/x.ttf` holding `Wine` → paths become `dlls/anomac.drv/…`, `programs/ano-cfg/…`, `include/ano/debug.h`; contents renamed; the `.ttf` is listed as binary with "wine"; a second run changes nothing; two paths that would collide → exit 1.
- [ ] **Step 3: Push and watch them fail** (`AnoWine Hygiene`, without `[skip ci]`). Expected: `ModuleNotFoundError: No module named 'rename_sources'`.
- [ ] **Step 4: Implement.** One compiled regex per stage: protected words and phrases are swapped for placeholders first and restored last; map entries next (program entries with `(?<![A-Za-z0-9_])…(?![A-Za-z0-9_])`); then the case rule. Text files are those whose first 8 KiB has no NUL and that decode as UTF-8 or Latin-1 (written back in the same encoding). Paths are renamed deepest first with `git mv`-free `os.rename`. Symlink targets are renamed too.
- [ ] **Step 5: Run the tests** (push, watch `AnoWine Hygiene`). Expected: the new tests pass; the rest stay green.
- [ ] **Step 6: Commit** (`feat: rename_sources renames a Wine tree by the owner's rule`).

### Task 2: `wine_tokens.py --gate` and license phrases

**Files:**
- Modify: `scripts/anowine/wine_tokens.py`, `scripts/anowine/test_wine_tokens.py`, `scripts/anowine/wine-allowlist.txt` (header)

**Interfaces:**
- Consumes: `load_allowlist` (Plan 3b).
- Produces: `wine_tokens.py ROOT... --out FILE --allowlist FILE [--gate]`. With `--gate`, exit 1 when any token's class is `wine` or `not-wine-candidate`, and print up to 200 hits as `<token>\t<count>\t<example file>`; exit 0 otherwise. Allowlist entries whose first field contains a space are phrases: category `license` only; their occurrences (ASCII and UTF-16LE) are removed before tokenizing.

- [ ] **Step 1: Write the failing tests:** `test_gate_fails_on_wine` (a tree with `ano.dll` holding `__wine_dbg_output` → exit 1, the token printed); `test_gate_passes_allowlisted` (only `WinExec` and an allowlisted `RKNS_5TwineE` → exit 0); `test_license_phrase` (UTF-16 `the Wine project authors` with the phrase allowlisted as `license` → no `Wine` token; the same text without the entry → `Wine` counted; a phrase entry with category `not-wine` → `ValueError` naming the line).
- [ ] **Step 2: Push and watch them fail** (`AnoWine Hygiene`).
- [ ] **Step 3: Implement** to the interface.
- [ ] **Step 4: Run the tests** (push, watch). Expected: green.
- [ ] **Step 5: Commit** (`feat: wine_tokens --gate fails on any token not on the allowlist`).

### Task 3: Engine 5.x: rename mode in `build-engine.sh`

**Files:**
- Modify: `scripts/anowine/build-engine.sh`, `.github/workflows/AnoEngine.yml`
- Create: `scripts/anowine/patches/rename/0001-ano-core-loader.patch`

**Interfaces:**
- Consumes: `rename_sources.py` (Task 1), `wine_tokens.py --gate` (Task 2).
- Produces:
  - Rename mode when `ANO_ENGINE_VERSION`'s major is 5 or more. Phase list: `check_host fetch_sources apply_patches rename_sources nix_inputs build_tools build_sdl2 configure_wine make_wine fetch_payloads install_tree bundle_libraries build_shims write_version verify_tree smoke_test package`; in 4.x mode `rename_sources` returns at once.
  - `rename_sources`: runs `rename_sources.py ano-src` with both rule files, writes its report to `logs/rename.txt`, applies `patches/rename/*.patch`, and renames the font name tables of every `.ttf` the report lists (fontTools, pinned version in the script).
  - Configure in rename mode: `--with-ano-tools=../build-tools`, `--prefix=/opt/ano`; the source folder is `ano-src`.
  - Output: `Libraries/Ano/...` and `Libraries/AnoRuntimeVersion.plist` as in Global Constraints; `<out-dir>` holds `Libraries.tar.gz`, `.sha256`, `AnoRuntimeVersion.plist`, `build-info.txt`.
  - `AnoEngine.yml`: input `version` (default `4.8.3`). Job `build` passes it as `ANO_ENGINE_VERSION`, and sets `ANO_ENGINE_WORK` to upstream's folder only for 4.x. Job `check`: the 4.8.3 comparison runs only for 4.x; for 5.x it boots a bottle with `ano-loader ano-boot --init` (`ANOPREFIX`, `ANODLLOVERRIDES`, `ANODEBUG=-all`) and runs `wine_tokens.py Libraries <bottle> --gate`.

- [ ] **Step 1: The failing check.** In `AnoEngine.yml` add the input and the 5.x branch of `check` (bottle and gate) and a `build` stub path: in rename mode `build-engine.sh` runs `check_host`, `fetch_sources`, `apply_patches`, `rename_sources`, then stops with "not implemented: rename build" after printing the rename report's counts. Push with `[skip ci]`, dispatch with `-f version=5.0.0`.
  Expected: `build` stops at "not implemented"; the report shows renamed paths and changed files, the binary files with "wine", and no rule conflict. Ledger the counts and every binary file listed.
- [ ] **Step 2: Implement the rename build.** Loader patch (`ano-core`, and `ntdll` starts it by that name); the layout, links and plist; `build_shims` writes `Ano builtin DLL`; payloads limited to MoltenVK, SDL2, gstreamer and Nix libraries; `Libraries/Ano/share/ano/NOTICES` says, in Ano's words, that the engine is a modified copy of software by the Wine project authors under the GNU LGPL 2.1, with the source at the repo URL (its only "wine" tokens are the license phrase and the repo URL, allowlisted as `license` and `code-only`); `verify_tree` and `smoke_test` use the new names (`ANOPREFIX`, `ANODEBUG=+anodiag` for the window test, `ano-loader ano-boot -u`) and add: `ano-loader --version` prints `ano-11.19`; no path under `Libraries` contains "wine" in any case; every Mach-O's signing identifier is free of "wine".
- [ ] **Step 3: Run it.** Push with `[skip ci]`, dispatch `version=5.0.0`, watch.
  Expected: `build` green with every smoke test. `check` boots the bottle; the gate fails and lists what is left. Ledger the hit count by component (the per-folder count from Plan 3b's analysis is the baseline: 316,716 occurrences in the Windows half).
- [ ] **Step 4: Fix rules until the gate's Wine-owned hits are gone.** For each remaining token: extend `rename-protect.txt` or `rename-map.txt`, or add an allowlist entry in an allowed category with its reason. A token that needs a category outside the design's list goes to the owner (ledger it; do not add it). Re-dispatch until the gate passes for everything except the aliases (Task 4).
- [ ] **Step 5: Re-run 4.8.3** (`version` default) to prove Plan 3b's reproduction still holds. Expected: `check` exits 0 as at the end of Plan 3b.
- [ ] **Step 6: Commit** (`feat: engine 5.0.0 is built from a renamed tree`).

### Task 4: Hidden aliases for closed parts

**Files:**
- Create: `scripts/anowine/aliases.txt`, `scripts/anowine/patches/rename/0002-ano-aliases.patch`
- Modify: `scripts/anowine/wine-allowlist.txt` (category `alias`), `.github/workflows/AnoEngine.yml`

**Interfaces:**
- Consumes: the rename build (Task 3).
- Produces: `aliases.txt` rows. Provisional D3DMetal set (until the owner's listing): the builtin marker `Wine builtin DLL` accepted beside `Ano builtin DLL`; `ntdll.dll` exports `__wine_unix_call_dispatcher`, `__wine_dbg_output`, `__wine_dbg_header`, `__wine_dbg_get_channel_flags`, `__wine_dbg_strdup` as aliases of their renamed functions; `ntdll.so` looks up `__wine_unix_call_funcs` and `__wine_unix_call_wow64_funcs` when the new names are missing. Each row's `how confirmed` says `provisional: GPTK ABI as Whisky deploys it; confirm with ano-gptk-wine-names.txt`.

- [ ] **Step 1: The failing check.** In `check` (5.x), build with mingw a test DLL marked `Wine builtin DLL` that imports `__wine_dbg_output` from `ntdll` and a unix library that exports only `__wine_unix_call_funcs`; load both in the bottle. Push `[skip ci]`, dispatch `version=5.0.0`.
  Expected: the test DLL fails to load (missing import or not a builtin).
- [ ] **Step 2: Implement the patch** from `aliases.txt`; add each alias string to the allowlist as `alias` with the closed part's name.
- [ ] **Step 3: Run it.** Expected: the test DLL loads and calls through; the gate passes (aliases allowlisted).
- [ ] **Step 4: Commit** (`feat: hidden aliases for D3DMetal (provisional)`).

### Task 5: Report

**Files:**
- Modify: `spikes/REPORT.md` (section "## Plan 3c-1: the engine without wine"), workspace `CLAUDE.md`

- [ ] **Step 1:** Record: the rename counts (paths, files, binary files), the protect and map sizes, the allowlist by category, the gate's before and after, the alias list and its status, build time, and what 3c-2 inherits (DXVK, DXMT and mono still use Wine names). Update `CLAUDE.md` status.
- [ ] **Step 2: Commit** (`docs: Plan 3c-1 report`).
