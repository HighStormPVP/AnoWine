# Ano runtime 5.0.1: old names hidden from other programs

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Windows program running in Ano finds no "wine" by name:
- in the copyright line of the engine's modules;
- among ntdll's exported functions;
- in the Mac-side environment of a process that does not load Apple's D3DMetal;
- nor as readable text anywhere in the engine's own binaries.

Apple's D3DMetal keeps working.

**Architecture:** Two new patches on the renamed engine source, after 0001–0006.
- `0007-ano-hidden-aliases.patch`:
  - The loader rewrites the `__wine_` prefix to `__ano__` inside the memory of a module that carries the old `Wine builtin DLL` mark (Apple's files on disk are untouched).
  - Every export lookup reads `__ano__<name>` as `__ano_<name>`.
  - ntdll stops exporting the six old names.
  - The old text the engine still needs is stored XOR-encoded.
  - `WINED3DMETAL`/`WINEESYNC` are set only just before a marked module's Mac library is loaded.
- `0008-ano-version-copyright.patch` rewords the version-resource copyright line.

One Ano Engine build (version 5.0.1) carries both. It is published only after the owner's D3DMetal test on 5.0.0 and their yes.

**Tech Stack:** C patches to the renamed winecx source (dappermint/winecx `9f3f644`), bash, Python 3 (stdlib), mingw-w64 test programs, GitHub Actions (`Ano Engine`, `AnoWine Hygiene`), `gh`.

**Spec:** `docs/superpowers/specs/2026-11-18-ano-full-rename-design.md`. Read decision 4, the two further rules, and "Amended by the owner (2026-11-25, runtime 5.0.1)", which holds the owner's rulings for this plan.

## Global Constraints

- New copyright line, verbatim: `Copyright (c) 1993-2026 the authors listed in the file AUTHORS`. License texts (LICENSE, AUTHORS, NOTICES.md, the Symbol font record) keep their words.
- Apple's files on disk are never modified; only the in-memory image of a module with the old mark is rewritten.
- ntdll's export table holds no name containing "wine" (any case).
- Our binaries hold no readable `Wine builtin DLL`, `__wine_`, `WINED3DMETAL` or `WINEESYNC`. The encoded text is decoded through a volatile key, so the compiler cannot fold it back into readable text.
- Old names are set in a process's Mac-side environment only when a module with the old mark has its Mac library loaded. They are never passed to another program (0005/0006 stay).
- The allowlist only narrows. Its 11 `alias` rows are dropped only after 5.0.1 is published, since the published 5.0.0 still carries them. Categories stay the six fixed ones.
- Test-first: push RED, watch it fail in CI, then GREEN. Script-only pushes carry `[skip ci]`; dispatch workflows by hand with `gh ... -R HighStormPVP/AnoWine`.
- Patches are written with `core.autocrlf=false` (LF). New scripts are LF, mode 100755, and stage by path.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Publishing v5.0.1 needs the owner's yes, after their Ano 9 D3DMetal result on 5.0.0 (test item 4).

## Review Focus

1. **Real D3DMetal**, which CI cannot run. It must still start a DirectX 12 game, as on 5.0.0. This fails if Apple's DLLs reach an old name some way the rewrite misses: a name built at run time, a `wine_` name without underscores, or a lookup through a module other than the one asking. Owner's test only; the stand-in covers the three known paths (import, `RtlFindExportedRoutineByName`, `GetProcAddress`).
2. **The first D3D load in a busy process.** `setenv` runs while other threads may call `getenv`. The expected result is no crash. Kept under the loader's virtual mutex; review the call site.
3. **A marked module's own data that merely looks like a name**, for example an exported `__wine_*` name or a tail-merged string. The rewrite skips executable sections and the module's export directory, and changes only the 7-byte prefix in place, so no tail moves.
4. **32-bit and wow64 processes.** The i386 ntdll gets the same code. Unmarked programs must behave exactly as before; the probe runs as x86_64 only.
5. **Compiler folding.** If the optimiser turns a decode into immediates, readable text comes back. The strict token scan in `check-hidden-names.sh` catches this on every build.

---

### Task 1: The checks, RED on 5.0.0

**Files:**
- Modify: `scripts/anowine/tests/aliases/aliastest.c`, `ntdll-aliases.def`, `aliastest_unix.c`, `envrun.c`
- Create: `scripts/anowine/tests/aliases/aliasprobe.c`, `plaintest.c`, `ntdll-ano.def`
- Modify: `scripts/anowine/check-aliases.sh`, `scripts/anowine/check-env-aliases.sh`
- Create: `scripts/anowine/check-hidden-names.sh`, `scripts/anowine/test-check-hidden-names.sh`
- Modify: `.github/workflows/AnoEngine.yml` (check job), `.github/workflows/AnoWineHygiene.yml`

**Interfaces:**
- Produces: `check-hidden-names.sh <Libraries> <bottle>`. Exit 0 = hidden; 1 = an old name or the old copyright line was found, or kernel32.dll lacks the new line; 2 = harness error. The last line on success starts `old names hidden: tokens 0`.
- Produces: the stand-in's output lines (`RESULT: alias_call(21) = 42`, `PROBE: ntdll hides the old names`, `plain: WINED3DMETAL=- WINEESYNC=- (call 0)`).

- [ ] **Step 1: Stand-in asks the dynamic ways too.** In `aliastest.c` `alias_call`, after the existing calls:
  - `RtlFindExportedRoutineByName(ntdll, "__wine_unix_call_dispatcher")` must equal `&__wine_unix_call_dispatcher`, else return -6.
  - `GetProcAddress(ntdll, "__wine_dbg_output")` must equal `(FARPROC)__wine_dbg_output`, else return -7.
  - Add `RtlFindExportedRoutineByName` to `ntdll-aliases.def`.

  The expected line is unchanged: `RESULT: alias_call(21) = 42`.
- [ ] **Step 2: `aliasprobe.c`, an ordinary (unmarked) program.**
  - For each of the six names `__wine_unix_call_dispatcher`, `__wine_unix_call`, `__wine_dbg_get_channel_flags`, `__wine_dbg_header`, `__wine_dbg_output`, `__wine_dbg_strdup`: `GetProcAddress(ntdll, name)` and `RtlFindExportedRoutineByName(ntdll, name)` must both be NULL. The latter is found through `GetProcAddress`.
  - Walking ntdll's export name table must find no name containing "wine" in any case.
  - Each failure prints `PROBE FAIL: <what>`. All passing prints `PROBE: ntdll hides the old names`; the exit code is 0 or 1.
- [ ] **Step 3: `check-aliases.sh` runs the probe.**
  - Build `aliasprobe.exe` with mingw.
  - Record `shasum -a 256` of the marked `aliastest.dll` in `$PE` before the run and again after it. A difference is a failure: "the marked DLL's file changed".
  - Require both the `RESULT … = 42` line and the `PROBE: ntdll hides the old names` line.
- [ ] **Step 4: A plain stand-in in `check-env-aliases.sh`.**
  - `plaintest.c` is a DLL that the script marks `Ano builtin DLL`. It imports `NtQueryVirtualMemory` and `__ano_unix_call` (through `ntdll-ano.def`) and exports `plain_env(struct env_args *)`, which calls unix entry 1.
  - `aliastest_unix.c` built with `-DANO_PLAIN` exports its table as `__ano_unix_call_funcs`, and as `__wine_unix_call_funcs` otherwise.
  - `envrun.c` loads `plaintest.dll` first and prints `plain: WINED3DMETAL=%s WINEESYNC=%s (call %d)`, then does what it did before.
  - The script removes the plaintest files afterwards, like the others.
  - New requirement: `plain: WINED3DMETAL=- WINEESYNC=- (call 0)`.
- [ ] **Step 5: `check-hidden-names.sh` and its self-test.**
  - (a) Build a strict allowlist: `wine-allowlist.txt` without its `alias` rows. Then run `wine_tokens.py <Libraries> <bottle> --allowlist strict --gate`.
  - (b) A Python pass over `Libraries/Ano/lib` and `<bottle>/drive_c`. Any file holding `the Wine project authors` in ASCII or UTF-16LE fails, with up to 20 files listed. `Libraries/Ano/lib/ano/x86_64-windows/kernel32.dll` must hold the UTF-16LE new line.
  - `test-check-hidden-names.sh` plants fake trees in a temp folder and covers four cases:
    - a clean tree exits 0;
    - `Wine builtin DLL` planted in a DLL exits 1 and names the token;
    - the UTF-16 old line in a DLL exits 1;
    - kernel32.dll without the new line exits 1.
- [ ] **Step 6: Wire.**
  - AnoEngine.yml check job: a step "Old names hidden from other programs" after "D3DMetal's variables, a hidden alias", same `if` and timeout, running `check-hidden-names.sh "$RUNNER_TEMP/ours/Libraries" "$RUNNER_TEMP/bottle"`.
  - Hygiene: a step running `test-check-hidden-names.sh "$GITHUB_WORKSPACE"`.
- [ ] **Step 7: Commit and push** with `[skip ci]`, staging by path.
- [ ] **Step 8: RED.**
  - Dispatch Hygiene. Expected: green, since the self-test tests the checker.
  - Dispatch Ano Engine with `version=5.0.0 engine_run=45326779119`. Expected: the check job fails at exactly three steps:
    - "Hidden aliases for closed parts": `PROBE FAIL` for the six names. `RESULT … = 42` still passes.
    - "D3DMetal's variables": `plain:` shows `WINEESYNC=1`.
    - "Old names hidden": the alias tokens, the old copyright line in N files, kernel32.dll without the new line.
  - Every other step stays as on 5.0.0.

### Task 2: Patches 0007 and 0008, GREEN in a 5.0.1 build

**Files:**
- Create: `scripts/anowine/patches/rename/0007-ano-hidden-aliases.patch`, `0008-ano-version-copyright.patch`
- Modify: `scripts/anowine/aliases.txt` (the "where" column), `scripts/anowine/rename-protect.txt` and `wine-allowlist.txt` (reasons only)

**Interfaces:**
- Consumes: 0002 (`alias_signature` in loader.c, mapping.c, fakedll.c; the six spec lines; the old dlsym in virtual.c), 0005 (`ano_env_aliases`, `ano_env_set_aliases` called in `start_main_thread`), 0006.
- Produces, in the renamed tree:
  - `include/ano/hidden.h`: `ANO_HIDDEN_KEY` 0x5a, `ANO_HIDE(c)`, `static inline char *ano_unhide( char *out, const char *in, unsigned int len )`, which reads the key through a volatile.
  - In loader.c:
    - `static void ano_rewrite_old_names( void *module, const IMAGE_NT_HEADERS *nt )`;
    - `find_name_in_exports` falls back from `__ano__<x>` to `__ano_<x>`;
    - `build_module` calls the rewrite when the old mark matched.
  - In virtual.c, `static BOOL ano_has_old_mark( const void *module )`. `load_builtin_unixlib` calls `ano_env_set_aliases()` before `dlopen` when it is true.

- [ ] **Step 1: Base.** In the renamed tree, `scratchpad/src3c5/ano-src` (renamed + 0001–0005 committed, 0006 in the working tree), commit 0006 as the base.
- [ ] **Step 2: Write 0007.**
  - loader.c:
    - Old mark decoded from an `ANO_HIDE` array.
    - The rewrite runs over sections that are readable and not executable, skipping the export directory. It replaces each `__wine_` that is preceded by a non-identifier byte and followed by an identifier byte with `__ano__`, after `NtProtectVirtualMemory(PAGE_READWRITE)`, and restores the protection.
    - The fallback is in `find_name_in_exports`.
  - ntdll.spec: drop the six `__wine_*` lines.
  - mapping.c and fakedll.c: the mark is decoded.
  - virtual.c: the table names are decoded; aliases are set before `dlopen` for marked modules.
  - env.c: the alias table is encoded.
  - unix/loader.c: drop the `ano_env_set_aliases()` call.

  Make the patch with `mkpatch.py`-style difflib against the base, LF only.
- [ ] **Step 3: Write 0008.** In `include/common.ver`, `VER_LEGALCOPYRIGHT_STR` becomes the verbatim line from Global Constraints.
- [ ] **Step 4: Check it locally.**
  - `git apply --check` of 0007 then 0008 on the base.
  - `spawn_sites.py` and `check_lengths.py` run against the patched tree.
  - A scan of the patched C files confirms that no new readable old text was added outside `ANO_HIDE(...)` comments.
- [ ] **Step 5: Docs in the same commit.** `aliases.txt` "where" column: rewritten in the marked module's memory; encoded text. Reasons in `rename-protect.txt`/`wine-allowlist.txt`: the copyright line now lives only in the license texts.
- [ ] **Step 6: Commit and push** with `[skip ci]`.
- [ ] **Step 7: GREEN.** Dispatch Ano Engine with `version=5.0.1`. Expected:
  - the build succeeds;
  - the check job is all green, including the three steps that were RED in Task 1, the gate, graphics, mono and app-on-engine;
  - the gate job is green.

  Record the run id and the `Libraries.tar.gz` sha256.

### Task 3: Notes, report and the owner's test item

**Files:**
- Create: `docs/anowine/runtime-5.0.1-notes.md`. It names the sha256 and the run, copies 5.0.0's notes format, and says what changed and that D3DMetal is checked by the owner's test.
- Modify:
  - `spikes/REPORT.md`: section "Runtime 5.0.1: old names hidden".
  - `docs/anowine/TESTING-ON-M2.md`: section "Ano 9: runtime 5.0.1", with items to update, the D3DMetal game, a DXVK game, and the version shown in Stability Diagnostics.

- [ ] **Step 1: Write the three documents.**
- [ ] **Step 2: Commit and push** with `[skip ci]`.

### Task 4: Release (only after the owner's D3DMetal result on 5.0.0 and their yes)

**Files:**
- Modify:
  - `.github/workflows/AnoEngine.yml`: the publish job gets `--target` set to the engine run's head SHA, from `gh run view "$RUN" --json headSha`.
  - `dist/pages/AnoRuntimeVersion.plist`: 5.0.1 and its sha.
  - `.github/workflows/AnoFeeds.yml`: `v5.0.1`.
  - `.github/workflows/AnoProxy.yml`: `RUNTIME_URL` and `RUNTIME_SHA256`.
  - `scripts/anowine/wine-allowlist.txt`: drop the 11 `alias` rows.

- [ ] **Step 1:** Ask the owner; stop here until they answer yes.
- [ ] **Step 2:** Dispatch Ano Engine with `version=5.0.1 engine_run=<Task 2 run> publish=true`. Expected: release v5.0.1, Latest.
- [ ] **Step 3:** Commit the feed, Feeds, Proxy and allowlist changes. Dispatch Feeds, Proxy, Hygiene and Test Build. Expected:
  - all green;
  - the Test Build's gate runs on 5.0.1 with the strict allowlist.
