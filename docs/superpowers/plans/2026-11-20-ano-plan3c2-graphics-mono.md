# Ano Plan 3c-2 — DXVK, DXMT and mono without "wine"

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Engine 5.0.0 carries DXVK and DXMT rebuilt from public source and wine-mono renamed, and a new bottle made with it needs no DLL overrides and shows no install dialog; the gate passes over the engine and the bottle.

**Architecture:** DXVK and the mono rename need nothing from the engine, so a new script, `build-payloads.sh`, makes them on an Ubuntu runner (plenty of runners, mingw GCC 13 like the original DXVK build) in a new `payloads` job; `build-engine.sh` takes that folder through `ANO_PAYLOADS`. DXVK's two trees are renamed with `rename_sources.py` (the shared map) before meson. Mono cannot be rebuilt (decision: names only), so `rename_binaries.py --pe` renames its PE files in place without changing any length, re-sorts export tables, and its support MSI and cabinet are unpacked, renamed and repacked with msitools and gcab. DXMT links against Wine's build tree, so it is built on the Mac inside `build-engine.sh` (new phase `build_dxmt` after `make_wine`), renamed the same way, against LLVM 15.0.7 that the workflow caches. A small engine patch stops Wine offering to download Gecko.

**Tech Stack:** bash, Python 3 (stdlib; fontTools as in 3c-1), meson 1.10.0, ninja, mingw-w64, glslang, msitools, gcab, LLVM 15.0.7, the 3c-1 engine build; GitHub Actions `ubuntu-24.04` and `macos-15`.

**Spec:** `docs/superpowers/specs/2026-11-18-ano-full-rename-design.md`: decisions 2, 4 and 7, the two further rules, "What counts", the parts table under Constraints, How 3, 5 and 8, Anti-goals. Research: `.superpowers/sdd/2026-11-19-ano-plan3c1-engine-rename/research-3c2.md` (not in git) and the inventory below.

## Global Constraints

- **Naming rule** as in 3c-1 (decision 2): protect list, then `scripts/anowine/rename-map.txt` (shared by every tree, so names match the engine's), then `wine`→`ano`, `Wine`→`Ano`, `WINE`→`ANO`.
- **Decision 7:** "Mono's file, folder and product names are renamed; its internal assembly names (`WineMono.*`) go on the allowlist. Gecko is no longer shipped (Steam does not use it; programs that need it can get it through ano-tricks)."
- **Pins:** DXVK-macOS `github.com/Gcenx/DXVK-macOS` `8f1e28deed3ad30802f7e1bdff428ec14e6e7817` (the `v1.10.3-20230507-repack` release, async patch included); DXVK `github.com/doitsujin/dxvk` `e4fd5e9e8d335e8a2c0814829207cbd421f7e40e` (v1.10.3, for 32-bit `dxgi.dll` only); DXMT `github.com/3Shain/dxmt` `589adb780354b461645b29999cefaf533594ee99` (v0.80) with submodules `external/nvapi` `d08488fcc82eef313b0464db37d2955709691e94` and `include/native/directx` `9df86f2341616ef1888ae59919feaa6d4fad693d`; LLVM `llvmorg-15.0.7`; wine-mono 11.3.0 with the SHA-256 already in `build-engine.sh`.
- **Layout** (as 4.x, renamed): `Libraries/DXVK/x64/{d3d10core,d3d11}.dll`, `Libraries/DXVK/x32/{d3d10core,d3d11,dxgi}.dll`, `Libraries/DXMT/{x64,x32}/` (front ends with the ordinary DOS stub at 0x40, `nvapi64.dll`, `nvngx.dll`), `lib/ano/{x86_64,i386}-windows/anometal.dll`, `lib/ano/x86_64-unix/anometal.so`, `share/ano/mono/ano-mono-11.3.0/`. No `share/ano/gecko`.
- **Allowlist categories** stay the six in `wine-allowlist.txt`; LLVM's `Twine` symbols are `not-wine`, `WineMono*` names are `mono-internal`. Anything else goes to the owner.
- **Anti-goal:** no graphics or .NET breakage to remove a name; a part that cannot be renamed without breaking goes to the owner.
- Never build arm64 Wine parts (DXMT's unix side is x86_64). Never fetch from github.io. Scripts LF, mode 100755. `gh -R HighStormPVP/AnoWine`. RED pushed and watched before GREEN. 3c-2 ships nothing.

## Inventory (wine-mono 11.3.0, 2026-11-20)

2,946 files, 61 distinct tokens. Build paths `/builds/mono/wine-mono/wine-mono-11.3.0/...` (2,677 `wine`, ASCII and a few UTF-16 without a NUL); `WineMono` 990 (assembly, GAC folder and file names: mono-internal); `Wine builtin DLL` 28; ntdll imports `__wine_dbg_{output,header,get_channel_flags,strdup}`; exports `wine_mono_install_assembly_preload_hook(_v2)`, `wine_mono_assembly_load_from_gac` (mscoree looks them up by name); `wine_get_version` in `SDL3.dll` and `libmono`; `WINEDEBUG`, `WINE_FTRACE_FILE`, `WINE_MONO_HIDETYPES`; `support/winemono-support.{msi,cab}` and `dotnetfakedlls.inf` (`WineFakeDlls`); not Wine: `winexe`, `Winexe`, `WinExe`, `WinEvent*`, `winEvent*`, `WINEVENT_*`, `winerror`, `swine`, `JRTwine`. DXVK and DXMT sources have no not-Wine tokens (scanned).

## Review Focus

1. A name DXVK or DXMT looks up at run time (`GetModuleHandle("winevulkan.dll")`, `GetProcAddress` names, `__wine_unix_call_funcs`) renamed in one place but not the other: the DLL loads, then fails inside a game.
2. `libmono`'s export table left unsorted after the rename: mscoree's `GetProcAddress` misses `ano_mono_*` and every .NET program fails.
3. The repacked support MSI missing a renamed reference (cabinet name, `MsiFileHash`, product name): mono's support install fails quietly and .NET programs that need the fake framework DLLs break.
4. A new bottle on the owner's Mac (no DLL overrides) stops on a Gecko or Mono dialog.
5. DXVK built by Ubuntu's GCC 13 behaving differently from the original GCC 13.1 build (async, crashes): CI only loads the DLLs; the owner's game test in 3c-5 is the real check.

---

### Task 1: The failing checks, and DXVK from source

**Files:**
- Create: `scripts/anowine/build-payloads.sh`, `scripts/anowine/check-graphics.sh`, `scripts/anowine/check-mono.sh`, `scripts/anowine/tests/graphics/loadtest.c`, `scripts/anowine/tests/mono/hello.cs`
- Modify: `.github/workflows/AnoEngine.yml`, `scripts/anowine/build-engine.sh`, `scripts/anowine/rename_sources.py` (`--protect` optional), `scripts/anowine/test_rename_sources.py`

**Interfaces:**
- Produces:
  - `build-payloads.sh <out-dir>` (Ubuntu 24.04): writes `<out>/DXVK/{x64,x32}`, `<out>/mono/ano-mono-11.3.0`, `<out>/payloads-info.txt`. Each source is cloned at its pin, renamed with `rename_sources.py <tree> --map rename-map.txt` (no protect list; exit 1 on a collision), and built as DXVK's `package-release.sh` does (`meson setup --cross-file build-win{64,32}.txt --buildtype release --strip -Dbuild_id=false`), plus `-Denable_d3d9=false -Denable_dxgi=false` for the macOS repack; upstream's 32-bit build gives `dxgi.dll` only.
  - `AnoEngine.yml`: job `payloads` (ubuntu-24.04, 5.x only) uploads artifact `ano-payloads`; `build` runs after it (also when it is skipped for 4.x) and passes the downloaded folder as `ANO_PAYLOADS`; `build-engine.sh` in rename mode copies it into the layout and `verify_tree` checks every file of the layout.
  - `check-graphics.sh <Libraries/Ano> <Libraries> <bottle>`: builds `loadtest.c` for x86_64 and i386 with mingw, loads every DXVK and DXMT DLL of its architecture by full path, prints `LOADED <name>` per DLL and `CREATE <name> <hresult>` for `D3D11CreateDevice`; exits 1 unless every DLL is `LOADED`. `CREATE` lines are reported, not required (CI has no GPU guarantee).
  - `check-mono.sh <Libraries/Ano> <bottle>`: compiles `hello.cs` with the runner's .NET SDK Roslyn (`dotnet <sdk>/Roslyn/bincore/csc.dll -nostdlib -r:<mono>/lib/mono/4.5/mscorlib.dll`), runs it with `ano-loader`; expects the line `hello from Ano mono`.
  - `rename_sources.py`: `--protect` optional (no protected text).

- [ ] **Step 1: Test for `--protect` optional** (`test_tree_without_protect`: `rename_tree` with rules from `load_rules(None, map)` renames `src/vulkan/presenter.cpp` containing `GetModuleHandleA("winevulkan.dll")` to `GetModuleHandleA("anovulkan.dll")`). Run `python3 -m unittest discover -s scripts/anowine -p 'test_*.py'`. Expected: FAIL (TypeError or no file). Implement; expected PASS.
- [ ] **Step 2: The failing CI checks.** Write `check-graphics.sh`, `check-mono.sh`, their test sources, and in `check` (5.x): the bottle step without `ANODLLOVERRIDES` and with a 15-minute limit on `ano-boot --init` (a dialog would hang it), then `check-graphics.sh`, `check-mono.sh`, the gate. Push with `[skip ci]`; dispatch `version=5.0.0` with `engine_run` set to the last green 3c-1 build. Expected: all three new checks fail (no DXVK, no DXMT, no mono; the boot may time out). Ledger the output.
- [ ] **Step 3: DXVK.** Write `build-payloads.sh` (DXVK part), the `payloads` job and `ANO_PAYLOADS` in `build-engine.sh`. Dispatch `version=5.0.0`. Expected: `payloads` green with five DLLs; `check-graphics.sh` prints `LOADED` for every DXVK DLL (DXMT still missing). Ledger the `CREATE` results and the gate's DXVK hits.
- [ ] **Step 4: Commit** (`feat: DXVK rebuilt from source without wine`).

### Task 2: DXMT from source

**Files:**
- Modify: `scripts/anowine/build-engine.sh`, `.github/workflows/AnoEngine.yml`, `scripts/anowine/wine-allowlist.txt`

**Interfaces:**
- Consumes: the renamed engine's build tree (`$WORK/build`), Task 1's layout checks.
- Produces: phase `build_dxmt` (5.x, after `make_wine`): clone at the pin with the two submodules at theirs, rename (no protect), LLVM 15.0.7 at `$ANO_LLVM_DIR` (built with DXMT's own CI cmake line when the cache is empty; the workflow caches it under a key with the LLVM version), meson 1.10.0, then for win64 `-Denable_nvapi=true -Denable_nvngx=true -Dnative_llvm_path=$ANO_LLVM_DIR -Dano_build_path=$WORK/build` (the option name follows the rename) and for win32 without LLVM; installed into the layout above, front ends with the ordinary DOS stub as in 4.x.

- [ ] **Step 1: Implement and dispatch** `version=5.0.0`. Expected: `check-graphics.sh` prints `LOADED` for every DXMT DLL, and loading `d3d11.dll` from `Libraries/DXMT/x64` brings in the builtin `anometal.dll`, which loads `anometal.so` (its `otool -L` shows `@rpath/anomac.so`, checked in `verify_tree`). LLVM's `Twine` symbols in `anometal.so` go on the allowlist as `not-wine` with the reason "LLVM's Twine class"; any other DXMT hit is fixed by the rule or goes to the owner.
- [ ] **Step 2: Commit** (`feat: DXMT rebuilt from source without wine`).

### Task 3: Renaming PE files in place

**Files:**
- Create: `scripts/anowine/rename-protect-mono.txt`
- Modify: `scripts/anowine/rename_binaries.py`, `scripts/anowine/test_rename_binaries.py`

**Interfaces:**
- Produces: `rename_binaries.py --protect F --map F --pe FILE...` with `rename_pe(data: bytes, rules) -> bytes`. Rules, in order: (1) a renamed path component keeps its length by repeating the separator after it (`/builds/mono/wine-mono/wine-mono-11.3.0/` → `/builds/mono/ano-mono//ano-mono-11.3.0//`), in ASCII and UTF-16LE; (2) a NUL-terminated ASCII or UTF-16LE string is renamed and NUL-padded; (3) any other change raises `ValueError` naming the offset; (4) when an export name changes, the export name pointer and ordinal tables are re-sorted by the new names (byte order). The output has the input's length. `rename-protect-mono.txt` protects `WineMono` (substring) and the not-Wine tokens of the inventory.

- [ ] **Step 1: Tests first** (`PeTests`, with a small PE built by a helper in the test file): `test_exports_resorted` (exports `mono_a`, `wine_mono_hook`, `zlib_x` → names `ano_mono_hook`, `mono_a`, `zlib_x`, each ordinal still pointing at its function); `test_path_keeps_length` (ASCII and an unterminated UTF-16 path); `test_terminated_strings` (`Wine builtin DLL\0` → `Ano builtin DLL\0\0`, `__wine_dbg_output\0` → `__ano_dbg_output\0\0`, UTF-16 `WINEDEBUG\0\0` → `ANODEBUG\0\0\0\0`); `test_protected` (`WineMono.I18N.dll`, `winexe`, `SetWinEventHook` unchanged); `test_unterminated_change_refused`. Push `[skip ci]`, dispatch Hygiene. Expected: FAIL.
- [ ] **Step 2: Implement.** Dispatch Hygiene. Expected: PASS.
- [ ] **Step 3: Commit** (`feat: rename PE files in place`).

### Task 4: wine-mono renamed

**Files:**
- Modify: `scripts/anowine/build-payloads.sh`, `scripts/anowine/rename_binaries.py`, `scripts/anowine/test_rename_binaries.py`, `scripts/anowine/wine-allowlist.txt`, `.github/workflows/AnoWineHygiene.yml` (msitools, gcab)

**Interfaces:**
- Consumes: `--pe` (Task 3).
- Produces: `rename_binaries.py --msi FILE`: `msidump` the tables and streams, rename table text with `rename_text` (mono protect list), rename the cabinet named in `Media` and every file in it (`gcab -x`, `--pe` or `rename_text`, `gcab -c`), recompute `MsiFileHash` rows (MD5 as four little-endian int32), `msibuild` a new MSI. In `build-payloads.sh`: fetch mono at its pin, `rename_sources.py` over the tree with the mono protect list (paths and text files), `--pe` over every PE file the report lists, `--msi` over the support MSI. `build-engine.sh` installs it at `share/ano/mono/ano-mono-11.3.0`.

- [ ] **Step 1: MSI test first** (`test_msi_renamed`, skipped without `msibuild`: an MSI with `Property` ProductName `Wine Mono Runtime`, a `Media` cabinet `#winemono-support.cab` holding `WineMono.Fixups.dll` and `x.inf` with `[WineFakeDlls]` → ProductName `Ano Mono Runtime`, cabinet `#anomono-support.cab`, `WineMono.Fixups.dll` kept, `[AnoFakeDlls]`, `MsiFileHash` equal to the new files' MD5). Hygiene installs msitools and gcab. Expected: FAIL, then implement, PASS.
- [ ] **Step 2: Dispatch** `version=5.0.0`. Expected: the bottle boots without overrides, `check-mono.sh` prints `hello from Ano mono`, and mono's support install is in the bottle under Ano's names. `WineMono*` tokens go on the allowlist as `mono-internal`; any other mono hit is fixed by a rule or goes to the owner.
- [ ] **Step 3: Commit** (`feat: wine-mono renamed`).

### Task 5: No Gecko, and the gate passes

**Files:**
- Create: `scripts/anowine/patches/rename/0003-ano-no-addon-download.patch`
- Modify: `scripts/anowine/build-engine.sh` (`verify_tree`: no `share/ano/gecko`)

- [ ] **Step 1:** The patch makes `dlls/appwiz.cpl/addons.c` (renamed tree) return when an addon is not found locally, instead of opening the download dialog (its URL now points at the repo anyway). Dispatch `version=5.0.0`. Expected: the bottle boots within the limit with no overrides, every 3c-2 check passes, and the gate passes over engine and bottle. Then re-run `version=4.8.3` (default): `check` exits 0 as at the end of Plan 3b.
- [ ] **Step 2: Commit** (`feat: no addon download dialog; 3c-2 gate green`).

### Task 6: Report

- [ ] **Step 1:** `spikes/REPORT.md` section "## Plan 3c-2: DXVK, DXMT and mono": pins, build times, what was renamed in each part, the allowlist entries added by category, `CREATE` results, the mono export re-sort, open risks (Review Focus 5). Update the workspace `CLAUDE.md` status. Commit (`docs: Plan 3c-2 report`).
