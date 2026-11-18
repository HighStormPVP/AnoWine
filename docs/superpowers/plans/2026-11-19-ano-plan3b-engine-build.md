# Ano Plan 3b — Ano builds the engine

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ano builds upstream's GPTK engine (Wine 11.19 with CrossOver's macOS patches) itself, with upstream's names, and proves the result equals upstream's engine v4.8.3 file for file, so that Plan 3c can rename inside the sources. It also delivers the two spikes the spec gives 3b: the "not Wine" token list, and a script that lists the Wine names Apple's D3DMetal uses.

**Architecture:** `scripts/anowine/build-engine.sh` is Ano's own build script. It follows the recipe upstream's CI used for v4.8.3: the same pinned sources, libraries, tools and settings. It downloads upstream's few recipe files (one Wine patch, two graphics shims, four smoke-test programs) at the pinned commit and checks their SHA-256; nothing of upstream's recipe is stored in this repo. A dispatch-only workflow, `Ano Engine`, runs the build on a hosted `macos-15` runner. Its `check` job compares the result with upstream's tarball using `compare_runtimes.py`. `wine_tokens.py` lists every "wine" token in the built tree and in a fresh bottle. `list-gptk-wine-names.sh` runs on the owner's Mac.

**Tech Stack:** bash; Wine/winecx autotools build (Rosetta, Homebrew mingw-w64 gcc, Nix-pinned x86_64 libraries, Xcode 16.4); Python 3 (stdlib only); perl (owner's Mac); GitHub Actions `macos-15` and `ubuntu-latest`.

**Spec:** `docs/superpowers/specs/2026-11-18-ano-full-rename-design.md`: decision 5, "How" step 2 and "Plan 3b". The recipe is upstream's `frankea/winecx-gptk` `.github/workflows/build.yml` at `12af86593bc5195c5015ca460dc1bbc8e81f3b13`, run 43653944195 (built v4.8.3 on hosted `macos-15`, image `macos-15-arm64` 20261104, Xcode 16.4, Homebrew `mingw-w64` 14.0.0_3 = gcc 16.2.0, `opt=release`, `runtime_version=4.8.3`, cold compiler cache, 75 minutes).

## Global Constraints

- **Nothing of upstream's recipe is copied into this repo** (owner's decision, 2026-11-19: `frankea/winecx-gptk` has no license). `build-engine.sh` and its comments are Ano's own. Upstream's recipe files are downloaded at build time from `https://raw.githubusercontent.com/frankea/winecx-gptk/12af86593bc5195c5015ca460dc1bbc8e81f3b13/<path>` and checked:

  | Recipe path | SHA-256 |
  |---|---|
  | `patches/0001-ntdll-kernelbase-keep-the-fiber-pointer-at-gs-0x20-on-macOS.patch` | `d36bfa79c78b0fac47e24aa77d397d73548620a87ae74f4914b58b1194ddd861` |
  | `gptk-video/d3d12shim.c` | `94420063c1a194b6bd85d3ff123b03a1b95cc4d7f9671bac7be73c929023f787` |
  | `gptk-video/d3d12shim.def` | `a520ea877f2ba3faea6e202aec03f4852909a1ed5a78a01aa2b75f1dec7bad09` |
  | `gptk-video/dxgishim.c` | `361b247d72e4fbed18ea47336cc03b2e0df57e62191ab2cb1bd6f0249463537c` |
  | `gptk-video/dxgishim.def` | `e2ea0bd01a798180d7b8f762cbfc1567672ef47f01ff3f6bd93f25a9a8e87fe0` |
  | `gptk-video/yuvblit.h` | `fe6de98e1806833c768d09427f971a58b0e615de2f2820176c9f72e04dfa3854` |
  | `tests/winmsg.c` | `2420818c6b0f9bc39ee71ec881569389788cd837204e716d2ab9a5e7adcdac2c` |
  | `tests/flsgetvalue2.c` | `0a2946185719d947cc3c9dd18894b4e5455cecd496b467dfc73b85913f52b7b9` |
  | `tests/mfprobe.c` | `d7a84052adf54987b6f112182dad3875abc1affef2e3f497943fe5098d2ca528` |
  | `tests/dlopenall.c` | `dbecc84a08029c64b8e56457fea2bf00d0fc8362e295c575aa6a311f56b081ad` |

- **Pinned build inputs**, the values v4.8.3 was built with:

  | What | Value |
  |---|---|
  | Wine source | `https://github.com/dappermint/winecx.git` at `9f3f6447844add700bc0dde650e4f398fd5f69ab`, full clone (Wine's version string comes from `git describe`) |
  | nixpkgs | `github:NixOS/nixpkgs/ac62194c3917d5f474c1a844b6fd6da2db95077d` |
  | FAudio (in the Wine tree; verify only) | 26.10 |
  | SDL2 | 2.32.10, `https://github.com/libsdl-org/SDL/releases/download/release-2.32.10/SDL2-2.32.10.tar.gz`, sha256 `5f5993c530f084535c65a6879e9b26ad441169b3e25d789d83287040a9ca5165` |
  | wine-mono | 11.3.0 (`MONO_VERSION` in `dlls/appwiz.cpl/addons.c`), `https://dl.winehq.org/wine/wine-mono/11.3.0/wine-mono-11.3.0-x86.tar.xz`, sha256 `54a1b0111c3fe4b785eae688af94d27e64995707ad648b6fee8000381b80d298` |
  | wine-gecko | 2.47.4 (`GECKO_VERSION`), `-x86.tar.xz` sha256 `2cfc8d5c948602e21eff8a78613e1826f2d033df9672cace87fed56e8310afb6`, `-x86_64.tar.xz` sha256 `fd88fc7e537d058d7a8abf0c1ebc90c574892a466de86706a26d254710a82814`, both under `https://dl.winehq.org/wine/wine-gecko/2.47.4/` |
  | DXVK macOS | `https://github.com/Gcenx/DXVK-macOS/releases/download/v1.10.3-20230507-repack/dxvk-macOS-async-v1.10.3-20230507-repack.tar.gz`, sha256 `acd1520ad105d8ef124a09c8e11a259a5dc8bdc565ad18e0e52693f9807b2477` |
  | DXVK upstream (32-bit `dxgi.dll` only) | `https://github.com/doitsujin/dxvk/releases/download/v1.10.3/dxvk-1.10.3.tar.gz`, sha256 `8d1a3c912761b450c879f98478ae64f6f6639e40ce6848170a0f6b8596fd53c6` |
  | DXMT | `https://github.com/3Shain/dxmt/releases/download/v0.80/dxmt-v0.80-builtin.tar.gz`, sha256 `8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d` |
  | MoltenVK | `https://github.com/KhronosGroup/MoltenVK/releases/download/v1.4.2/MoltenVK-macos.tar`, sha256 `f95765a6229cb7b915990a2890ce12ebe36a730b021545d3d52ae69ce4c4024e` |
  | Floor | `MACOSX_DEPLOYMENT_TARGET=15.0`; the SDK's major version must be 15 |
  | Optimisation | `-O3` for host and cross code (upstream's `opt=release`) |
  | Version stamped | `4.8.3` (env `ANO_ENGINE_VERSION`), so the version plist equals upstream's |
  | Reference engine | `https://github.com/frankea/Whisky/releases/download/v4.8.3/Libraries.tar.gz`, sha256 `08ffabd7b7c352470faee2b1d51061b341316e401439ca805c5302acc2fb8818` |
  | Ano 4.9.0 (negative check) | `https://github.com/HighStormPVP/AnoWine/releases/download/v4.9.0/Libraries.tar.gz`, sha256 `7951aa539c1e0f371b4f5083c31599e582f902c33f80617321d745cc164743e5` |

- **Upstream's names, unchanged.** `bin/wine`, `wine64`, `wineloader`, `wineserver`, `--prefix=/opt/whiskywine`, `Libraries/Wine/...`, `WhiskyWineVersion.plist`. Plan 3b ships nothing: no runtime release, no feed change, no app change.
- The runtime is x86_64 (unix half) plus i386 and x86_64 PE. Never build arm64 Wine parts for it. The build tools (`makedep`, `winebuild`, `wrc`, `widl`, `wmc`) are built native and only run during the build, as upstream does; they are not shipped.
- Actions: `actions/checkout@v6`, `actions/upload-artifact@v7`, `actions/download-artifact@v8`, `actions/cache@v5`, `maxim-lobanov/setup-xcode@ed7a3b1fda3918c0306d1b724322adc0b8cc0a90`, `DeterminateSystems/nix-installer-action@3138316df39ed29be04236d7ffc686fa525866aa` (v23, as upstream's run).
- Python scripts use the standard library only and are importable (`compare_runtimes.py`, `wine_tokens.py`), so `AnoWineHygiene` discovers `scripts/anowine/test_*.py`.
- Scripts are committed with LF endings and git mode 100755 (`check-hygiene.sh`). Edit backslash-heavy text with the Edit/Write tools, not heredocs.
- CI only; the dev machine is Windows.
  - `gh` always takes `-R HighStormPVP/AnoWine`.
  - A task is done when its workflow runs are green.
  - RED is pushed and watched before GREEN.
  - Mac runners are often "not acquired" (10+ times in a row on 2026-11-18): re-run with `gh run rerun <id> --failed -R HighStormPVP/AnoWine`.
  - `Ano Engine` is dispatch-only: `gh workflow run AnoEngine.yml -R HighStormPVP/AnoWine --ref main`.
- Commits go to `main` of the fork, the established workflow. Each commit ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Plans live in `docs/superpowers/plans/`, which upstream's `.gitignore` ignores: `git add -f`.

## Decisions made in this plan (not in the spec; list them for the owner)

- **Our own script, upstream's recipe files downloaded** (the owner's choice). It replaces the spec's "bring the CI build in unchanged"; the proof of "unchanged" is the output comparison.
- **What "equal" means** (`compare_runtimes.py`):
  - The trees must match: the same paths, kinds, symlink targets and execute bits.
  - Every file must be byte-identical, or identical once PE timestamps and checksums are zeroed.
  - Where a Mach-O or PE file matches only by interface (architectures, minimum macOS, exports, imports, dependencies, signing identifier), the result is "equivalent". That is accepted only when `build-info.txt` shows the toolchain differs from upstream's run, and each such file is recorded with that cause.
  - One expected difference: `Libraries/Wine/lib/external/README` uses Ano's own wording.
- **Xcode 16.4**, the version that built v4.8.3, is selected explicitly; the build stops if the SDK is not macOS 15.
- **Dispatch-only, hosted only, no publish.** A build holds a Mac runner for about 75–120 minutes. The compiler cache (`ccache`, 4 GB) is kept in the Actions cache, so later runs are faster.
- **`build-engine.sh` phases are functions in a fixed order.** Plan 3c inserts its rename step after `apply_patches`.

## Found while planning (for Plan 3c or the owner, no action here)

- Upstream found that a `kernelbase.dll` built with llvm-mingw stops Steam's login, so the engine's PE half is built with gcc. Ano 4.9.0's five rebuilt modules (user32, services, winedbg, ano-boot, ano-device) were built with llvm-mingw. If Ano-8's Steam test shows login trouble, they are the first suspect. Plan 3c builds everything with gcc through `build-engine.sh`.
- `dappermint/winecx` and `frankea/winecx-gptk` are third-party repos. For LGPL source availability, the 5.0.0 release (3c) should attach the exact Wine source it was built from.
- The shims `d3d12shim.dll` and `dxgishim.dll` come from unlicensed code. Ano 4.9.0 already ships them, as upstream Whisky does. The owner could ask dappermint to add a license.
- Upstream has a newer engine fix after v4.8.3 (`frankea/winecx-gptk` 438dc97, wow64 control messages); worth taking in 3c.

## Review Focus

1. **Toolchain drift on the runner.** If the runner image has a different Xcode, SDK or mingw-w64 than upstream's run, the build can differ quietly. Expected: the SDK check stops a wrong SDK, and `build-info.txt` records every tool version so `compare_runtimes.py`'s "equivalent" files can be traced to a cause. Test: Task 2, `check_host` and the `check` job.
2. **Optional libraries silently missing** (ffmpeg, gstreamer, SDL2). Wine's configure only warns, which would ship a runtime with no video, no media or no controllers. Expected: the build fails. Test: Task 2, the configure gates and `verify_tree`.
3. **A runtime that works only on the builder** (Nix store paths left in a dylib). Expected: the build fails. Test: Task 2, the relocatability check and `dlopenall` over the bundled files.
4. **The comparator calling different files equal.** Zeroing too much of a PE header, or matching by interface, would hide a real change. Expected: a code-byte change is never "timestamps", and runtime 4.9.0 is never equal to v4.8.3. Tests: Task 1's unit tests and its real-data self-check.
5. **"wine" hidden in UTF-16 text** (version resources, wide strings in DLLs). The 3c gate depends on the token list seeing these. Expected: UTF-16LE tokens are counted. Test: Task 3, `test_wine_tokens.py`.

---

### Task 1: `compare_runtimes.py`, proven on real runtimes

**Files:**
- Create: `scripts/anowine/compare_runtimes.py` (mode 755), `scripts/anowine/test_compare_runtimes.py`
- Create: `.github/workflows/AnoEngine.yml` (job `check`, self-check steps only)

**Interfaces:**
- Produces: `compare_runtimes.py OURS REFERENCE [--report FILE] [--expect-different RELPATH]...`, where OURS and REFERENCE are directories that contain `Libraries/`.
  - Exit codes: `0` reproduced, `2` equivalent only, `1` different.
  - Report: one summary line, `summary: identical=N timestamps=N interface=N different=N only-in-ours=N only-in-reference=N expected=N`, then one line per non-identical path: `<class>\t<relpath>\t<reason>`. Classes: `timestamps`, `interface`, `different`, `only-in-ours`, `only-in-reference`, `expected`.
  - Module functions used by later tasks and tests:
    - `walk_tree(root: Path) -> dict[str, Entry]`, where `Entry` is a NamedTuple `(kind: str, executable: bool, target: str | None)` and `kind` is `file`, `dir` or `link`;
    - `pe_normalized(data: bytes) -> bytes | None`;
    - `pe_interface(data: bytes) -> dict`;
    - `macho_interface(path: Path) -> dict`;
    - `classify(ours: Path, ref: Path, macho_interface=macho_interface) -> tuple[str, str]`;
    - `compare(ours: Path, ref: Path, expected: set[str]) -> Result`, where `Result` is a NamedTuple `(exit_code: int, rows: list[tuple[str, str, str]], counts: dict[str, int])` and `rows` holds `(class, relpath, reason)` for every non-identical path;
    - `main(argv: list[str]) -> int`.

- [ ] **Step 1: Write the failing tests** in `scripts/anowine/test_compare_runtimes.py`. It holds a helper `make_pe(timestamp=0, checksum=0, export_ts=0, exports=(), imports=None, code=b"\x90")`. The helper builds a minimal PE32+ (machine 0x8664): DOS header with `e_lfanew=0x80`, one section at RVA 0x1000 holding an export directory, an import descriptor with its lookup table and hint/name entries, and `code`. Each test builds two `Libraries/` trees in a temp dir and calls `compare`:
  - `test_identical_trees_reproduce`: same files → exit 0, all `identical`.
  - `test_path_only_on_one_side_is_different`: an extra file → `only-in-ours`, exit 1.
  - `test_symlink_target_and_exec_bit_count`: same path, different link target → exit 1; same bytes, exec bit differs → exit 1.
  - `test_pe_timestamps_only`: `make_pe(timestamp=1)` vs `make_pe(timestamp=2, checksum=7, export_ts=3)` → `timestamps`, exit 0.
  - `test_pe_code_byte_is_interface_not_timestamps`: `code=b"\x90"` vs `code=b"\xcc"`, same exports and imports → `interface`, exit 2.
  - `test_pe_export_change_is_different`: exports `("a",)` vs `("a", "b")` → `different`, reason names `b`, exit 1.
  - `test_text_difference_is_different_unless_expected`: two text files differ → exit 1; with `expected={"Libraries/x.txt"}` → class `expected`, exit 0.
  - `test_macho_uses_interface`: two files starting `b"\xcf\xfa\xed\xfe"` that differ. `classify` is called with a fake `macho_interface` returning equal dicts → `interface`; returning dicts that differ in `imports` → `different`, reason names the import.

- [ ] **Step 2: Push and watch them fail.** Commit (`test: compare_runtimes must tell a rebuild from a different runtime`) and push **without** `[skip ci]`, because `AnoWine Hygiene` must run. CI.yml starts too; let it run.
  Run: `gh run watch <AnoWine Hygiene run id> -R HighStormPVP/AnoWine`
  Expected: "Python tests" fails with `ModuleNotFoundError: No module named 'compare_runtimes'`.

- [ ] **Step 3: Implement `scripts/anowine/compare_runtimes.py`.**
  - `pe_normalized` zeroes these fields: the COFF `TimeDateStamp` (`e_lfanew+8`), the optional header's `CheckSum` (`+64`), the export directory's `TimeDateStamp`, every debug directory entry's `TimeDateStamp`, and every resource directory table's `TimeDateStamp` (walk the resource tree). RVAs map to file offsets through the section table.
  - `pe_interface` returns `machine`, sorted export names, sorted imports (`dll.lower()!name` or `dll.lower()!#ordinal`), and the 16 bytes at 0x40.
  - `macho_interface` uses macOS tools and returns:
    - `lipo -archs`;
    - `minos` from `otool -l` `LC_BUILD_VERSION`;
    - `otool -D`;
    - `otool -L` dependencies;
    - `LC_RPATH` paths;
    - `nm -gUj` and `nm -uj`;
    - `Identifier=` from `codesign -dv`.
  - `classify` returns:
    - `identical` for equal bytes;
    - `timestamps` for PE files equal after `pe_normalized`;
    - `interface` for Mach-O or PE files whose interface dicts are equal;
    - otherwise `different`, with a reason naming the first differing key and up to 5 differing items.

- [ ] **Step 4: Run the tests to verify they pass.**
  Commit (`feat: compare_runtimes.py proves whether two runtimes are the same build`) and push (without `[skip ci]`). Run: `gh run watch <AnoWine Hygiene run id> -R HighStormPVP/AnoWine`
  Expected: "Python tests" passes, including the 8 new tests.

- [ ] **Step 5: Add the real-data self-check.** Create `.github/workflows/AnoEngine.yml` (name `Ano Engine`, `workflow_dispatch` only, `permissions: contents: read`, env with the reference and 4.9.0 URLs and digests). Job `check` (`macos-15`, timeout 60):
  - check out the repo;
  - download and verify both tarballs, extracting each with `tar -xzf` into its own directory;
  - self-check 1: `compare_runtimes.py ref ref` must exit 0 with `different=0 interface=0`;
  - self-check 2: `compare_runtimes.py ano490 ref --report self2.txt` must exit 1, and `self2.txt` must contain the lines starting `different\tLibraries/Wine/lib/wine/x86_64-unix/ntdll.so\t` and `only-in-ours\tLibraries/Wine/bin/ano-loader\t`;
  - upload the reports as artifact `engine-compare` (`if: always()`).

  These self-checks are the real-data test of the code that Steps 1–4 drove RED to GREEN. Commit (`ci: Ano Engine self-checks compare_runtimes.py on real runtimes [skip ci]`), push, dispatch.
  Expected: job `check` green, and `self2.txt` lists the 4.9.0 renames.

### Task 2: `build-engine.sh` and the `Ano Engine` build

**Files:**
- Create: `scripts/anowine/build-engine.sh` (mode 755)
- Modify: `.github/workflows/AnoEngine.yml` (add job `build`; job `check` needs it and compares)
- Modify: `spikes/REPORT.md` (new section "Plan 3b: Ano builds the engine"), workspace `CLAUDE.md` (workflow table: `AnoEngine.yml`)

**Interfaces:**
- Consumes: `compare_runtimes.py` (Task 1).
- Produces:
  - `build-engine.sh <out-dir>`, with env `ANO_ENGINE_VERSION` (required, `major.minor.patch`) and `ANO_ENGINE_WORK` (default `${RUNNER_TEMP:-${TMPDIR:-/tmp}}/ano-engine`).
  - It writes `<out-dir>/Libraries.tar.gz`, `<out-dir>/Libraries.tar.gz.sha256`, `<out-dir>/WhiskyWineVersion.plist` and `<out-dir>/build-info.txt`.
  - Phases are shell functions run in this order: `check_host fetch_sources apply_patches nix_inputs build_tools build_sdl2 configure_wine make_wine fetch_payloads install_tree bundle_libraries build_shims write_version verify_tree smoke_test package`.
  - Each phase prints `== <phase>` and its time; `build-info.txt` gets them.
  - The work dir keeps upstream's relative layout (`winecx/`, `build-tools/`, `build/`, `staging/`, `Libraries/`), with configure run as `../winecx/configure` from `build/`, so relative source paths baked into binaries match.
  - Workflow artifact `ano-engine` holds the four output files.
  - Workflow input `engine_run` (optional run ID). When set, `build` is skipped and `check` downloads `ano-engine` from that run (`download-artifact` with `run-id` and `github-token`; workflow permissions `contents: read`, `actions: read`). `check` runs when `build` succeeded or was skipped. This lets later tasks iterate on `check` without a new build.

What each phase must do (the recipe of upstream's run, in Ano's words; the pinned values are in Global Constraints):

| Phase | Must |
|---|---|
| `check_host` | Run only on macOS arm64 where Rosetta runs `arch -x86_64 /usr/bin/true`. Fail unless `xcrun --show-sdk-version` has major 15. Fail if `nix`, `x86_64-w64-mingw32-gcc`, `i686-w64-mingw32-gcc`, `x86_64-w64-mingw32-strip`, `cmake`, `git` or `python3` is missing. Write `build-info.txt`: `ImageOS`, `ImageVersion`, `xcode-select -p`, SDK version, `clang --version`, both mingw gcc versions, `brew list --versions mingw-w64`, `nix --version`, `ccache --version` if present. If `ccache` exists, set it up with `CCACHE_DIR=$HOME/.ccache`, max size 4G, content compiler check, sloppiness `time_macros,locale,include_file_mtime,include_file_ctime`, base dir the work dir, no hash dir, file clone, inode cache. Make wrappers in `ccache-bin/` for both mingw gccs with the real paths baked in. |
| `fetch_sources` | Full `git clone` of winecx, then `checkout --detach` at the pinned commit. Record `git describe --tags` in `build-info.txt`. Download the recipe files into `recipe/<path>` and check each SHA-256 (fail on mismatch). Fail unless `libs/faudio/include/FAudio.h` says major 26, minor 10. |
| `apply_patches` | `git -C winecx apply` every `recipe/patches/*.patch` in name order. (Plan 3c adds `rename_sources` after this.) |
| `nix_inputs` | Build bison, flex and pkg-config from the pinned nixpkgs for the host. For x86_64-darwin, build outputs `dev`, `out` and `lib` (where they exist) of: freetype gnutls libpng zlib brotli bzip2 nettle libtasn1 libidn2 p11-kit libunistring gmp vulkan-headers ffmpeg-headless glib orc gst_all_1.gstreamer gst_all_1.gst-plugins-base gst_all_1.gst-plugins-good gst_all_1.gst-plugins-bad gst_all_1.gst-libav. Keep the list of store paths; derive `PKG_CONFIG_PATH`, `-I` and `-L` flags from them. |
| `build_tools` | Native build in `build-tools/` with native nix freetype (dev, out), libpng.dev, zlib.dev, brotli.dev and bzip2.dev. Configure flags: `--enable-archs=i386,x86_64 --without-x --without-wayland --without-gstreamer --without-oss --without-alsa --without-pulse --without-sane --without-usb --without-v4l2 --without-pcap --without-capi --without-opencl --without-ffmpeg --without-cups --disable-tests`. Run `make __tooldeps__`. Then make `build-tools/nls/` a real directory holding a link `locale.nls → ../../winecx/nls/locale.nls`, and fail unless it resolves. |
| `build_sdl2` | Build SDL2 2.32.10 with cmake: Release, `x86_64`, deployment target 15.0, shared only, no tests. Install into a prefix; fail without `libSDL2-2.0.0.dylib` and `SDL2/SDL.h`. |
| `configure_wine` | Settings: `CC="clang -arch x86_64"` and `CXX="clang++ -arch x86_64"`, each prefixed with `ccache` when it exists; the mingw wrappers first on `PATH`. `CFLAGS="-O3 -Wno-error=implicit-function-declaration -Werror=unguarded-availability-new <nix -I>"`, `CROSSCFLAGS=-O3`, `LDFLAGS=<nix -L>`. Cache variables: `ac_cv_func_pipe2=no`, soname freetype `libfreetype.6.dylib`, gnutls `libgnutls.30.dylib`, MoltenVK `libMoltenVK.dylib`, SDL2 `libSDL2-2.0.0.dylib`, `SDL2_CFLAGS=-I<sdl2>/include/SDL2`. Configure flags: `--host=x86_64-apple-darwin24 --with-wine-tools=../build-tools --enable-archs=i386,x86_64 --disable-tests --without-x --without-wayland --without-oss --without-alsa --without-pulse --without-sane --without-usb --without-v4l2 --without-pcap --without-capi --without-opencl --without-cups --prefix=/opt/whiskywine`. Fail unless `include/config.h` has `HAVE_FFMPEG 1` and `SONAME_LIBSDL2`, and `Makefile` has a non-empty `GSTREAMER_LIBS`. |
| `make_wine` | `make -j<1.5 × logical CPUs>`, logged. Fail if the log says a symbol "has been marked as being introduced in macOS" (above the floor). |
| `fetch_payloads` | Read `MONO_VERSION` and `GECKO_VERSION` from `addons.c`, and fail unless they are 11.3.0 and 2.47.4. Download and verify mono, both geckos, both DXVKs, DXMT and MoltenVK. Extract them; thin `libMoltenVK.dylib` to x86_64. |
| `install_tree` | `make -j install-lib DESTDIR=../staging`. Copy mono and gecko into `share/wine/mono` and `share/wine/gecko`, then the staging `bin`, `lib` and `share` into `Libraries/Wine/`. DXMT: its `x86_64-unix/` goes into `lib/wine/x86_64-unix/`, and `winemetal.dll` into `x86_64-windows/` (and `i386-windows/` if shipped); its d3d DLLs are not builtins. Per-bottle payloads: `Libraries/DXVK/` = the macOS repack tree plus upstream DXVK's `x32/dxgi.dll`; `Libraries/DXMT/x64` = DXMT `x86_64-windows`, `x32` = `i386-windows`. In `Libraries/DXMT/{x64,x32}/{d3d11,d3d10core,dxgi}.dll`, overwrite the 16 bytes at 0x40 with the standard DOS stub bytes `0e 1f ba 0e 00 b4 09 cd 21 b8 01 4c cd 21 90 90`, and verify no "Wine builtin" remains there. Delete `*.a` under `lib/wine/*-windows`, then `x86_64-w64-mingw32-strip --strip-debug` every file there. `bin/wine`, `bin/wine64` and `bin/wineloader` become symlinks to `../lib/wine/x86_64-unix/wine`; `bin/wine64 --version` must run. |
| `bundle_libraries` | Copy every nix `lib/gstreamer-1.0/*.dylib` into `Libraries/Wine/lib/gstreamer-1.0/`, and `libMoltenVK.dylib` and `libSDL2-2.0.0.dylib` into `Libraries/Wine/lib/`. Walk the `/nix/store` dependency closure, seeded with `libfreetype.6.dylib`, `libgnutls.30.dylib`, every `lib/wine/*-unix/*.so`, `bin/wine` and the plugins, copying each library flat into `lib/`. Then fix up every `lib/*.dylib*`, `lib/gstreamer-1.0/*.dylib*`, every file in `bin/` and every `lib/wine/**/*.so`: a `*.dylib*` gets id `@loader_path/<name>`; each `/nix/store` dependency becomes `@loader_path/<relative path to lib>/<name>`, except a `libiconv*` dependency of a file that imports `_iconv`, which becomes `/usr/lib/libiconv.2.dylib`; then `codesign -f -s -`. Links: `libfreetype.dylib → libfreetype.6.dylib`, `libSDL2.dylib → libSDL2-2.0.0.dylib`. Finally add rpath `@loader_path/../../` to each `lib/wine/*-unix/*.so` and re-sign it. |
| `build_shims` | Into `Libraries/Wine/lib/gptk-video/`: `d3d12shim.dll` = `x86_64-w64-mingw32-gcc -shared -O2 -fno-strict-aliasing -o … recipe/gptk-video/d3d12shim.c recipe/gptk-video/d3d12shim.def -Irecipe/gptk-video -luuid -ldxguid`. `dxgishim.dll` is built the same way from `dxgishim.c` and `.def`, without `-I`. In each, refuse if `e_lfanew < 0x60`, then write `Wine builtin DLL` and 16 NUL bytes at 0x40. Create `Libraries/Wine/lib/external/README`, in Ano's own words: Apple's Game Porting Toolkit payload (`D3DMetal.framework`, `libd3dshared.dylib`) goes here when the user imports it; the four unix bridges in `x86_64-unix` are symlinks to `../../external/libd3dshared.dylib`; it is not shipped because it is not redistributable. |
| `write_version` | `Libraries/WhiskyWineVersion.plist`: keys `gptkCapable` true, `dxvkVersion` `1.10.3`, `dxmtVersion` `0.80`, `version` {`major`, `minor`, `patch`} from `ANO_ENGINE_VERSION`. Byte layout: an XML plist with a two-space indent, equal to upstream's 4.8.3 file (Task 2's `check` compares it). |
| `verify_tree` | Fail on any of: an absolute id or dependency outside `/usr/lib` and `/System` in any Mach-O; a `minos` above 15; an undefined symbol (strong or weak) in any Mach-O that is in neither the SDK's `.tbd` stubs nor any bundled Mach-O's exports; fewer than 501 files in `lib/wine/i386-windows`; `x86_64-windows/ntdll.dll` of 1,500,000 bytes or more; a missing `share/wine/mono/wine-mono-*`, `gecko/wine-gecko-*-x86` or `gecko/wine-gecko-*-x86_64`; missing `Libraries/DXVK/x64/d3d11.dll`, `Libraries/DXVK/x32/dxgi.dll`, `x86_64-unix/winemetal.so` or `lib/external`; a builtin `d3d11`, `dxgi` or `d3d10core` containing `DXMT_` or `dxmt.con`; a builtin `x86_64-windows/nvapi64.dll`; `winedmo.so` not linking `libavcodec`; `winegstreamer.so` not linking `libgstreamer-1.0`; 50 or fewer gstreamer plugins; `winebus.so` containing `SDL support not compiled in`; no `lib/libSDL2-2.0.0.dylib`. |
| `smoke_test` | Build `winmsg.exe` (`-luser32`), `flsgetvalue2.exe`, `mfprobe.exe` (`-lmfplat -lole32`) with `x86_64-w64-mingw32-gcc -O2`, and `dlopenall` with `clang -arch x86_64 -O2`. In a fresh prefix, with `DYLD_FALLBACK_LIBRARY_PATH=Libraries/Wine/lib` and `WINEDLLOVERRIDES="mscoree=d;mshtml=d"`, run `wine64 wineboot -u`. Then fail unless: `winmsg.exe` under `WINEDEBUG=+winediag` prints `RESULT: windows ok` and no `nodrv_CreateWindow`; `flsgetvalue2.exe` exits 0; `mfprobe.exe` prints `RESULT: media foundation has decoders`; `dlopenall` over every bundled `*.dylib*` and `*.so` prints `RESULT: 0 of`. |
| `package` | `tar -czf Libraries.tar.gz Libraries`; write the SHA-256 file; copy the plist and `build-info.txt` into `<out-dir>`. |

- [ ] **Step 1: The failing check.** In `AnoEngine.yml`, add after the self-checks in job `check`:
  - download artifact `ano-engine`, extract it to `ours/`;
  - run `compare_runtimes.py ours ref --report compare.txt --expect-different Libraries/Wine/lib/external/README`;
  - run `cmp` of `ours/Libraries/WhiskyWineVersion.plist` against the reference's;
  - upload `compare.txt` and `build-info.txt`.

  Add job `build` with a stub step: `build-engine.sh` exists and only runs `check_host`, then exits 1 with "not implemented". Make `check` need `build`. Push with `[skip ci]`, dispatch.
  Expected: `build` fails at "not implemented" after `check_host` prints the tool versions. Read them and compare with upstream's run: Xcode 16.4, mingw-w64 14.0.0_3, gcc 16.2.0. Ledger any difference.

- [ ] **Step 2: Implement every phase** in `build-engine.sh` as the table says. Job `build` (`macos-15`, timeout 300):
  - check out the repo;
  - Rosetta;
  - select Xcode 16.4 with `setup-xcode`;
  - `brew install ccache mingw-w64` (only what is missing);
  - `actions/cache` for `~/.ccache`, key `ccache-<winecx commit>-<run id>`, restore keys `ccache-<winecx commit>-` and `ccache-`;
  - the nix installer with `determinate: false` and `extra-conf: extra-platforms = x86_64-darwin`;
  - `ANO_ENGINE_VERSION=4.8.3 build-engine.sh "$RUNNER_TEMP/out"`;
  - upload `ano-engine` (retention 14 days).

  The job `check` also installs Rosetta (Task 3 boots a prefix there).

- [ ] **Step 3: Run it.** Push with `[skip ci]`, dispatch, watch both jobs.
  Run: `gh run watch <id> -R HighStormPVP/AnoWine`
  Expected: `build` green, with every gate and smoke test passing. In `check`, the plist `cmp` is silent and `compare_runtimes.py` exits 0, or exits 2 with every `interface` file explained by a toolchain difference recorded in `build-info.txt`. Exit 1 is a bug in the build: debug it (superpowers:systematic-debugging), never widen the comparator to pass.

- [ ] **Step 4: Report.** Add `spikes/REPORT.md` section "## Plan 3b: Ano builds the engine". It records: build time per phase, cold and with ccache (dispatch a second run); the tool versions next to upstream's; the comparison summary line; every non-identical file with its cause. Add `AnoEngine.yml` to the workspace `CLAUDE.md` workflow table: "dispatch-only: builds the engine with `build-engine.sh` and compares it with upstream's v4.8.3".

- [ ] **Step 5: Commit**:
  ```bash
  git add scripts/anowine/build-engine.sh .github/workflows/AnoEngine.yml spikes/REPORT.md
  git commit -m "feat: build the engine ourselves and prove it equals upstream's v4.8.3"
  ```

### Task 3: "wine" token inventory and the not-Wine allowlist

**Files:**
- Create: `scripts/anowine/wine_tokens.py` (mode 755), `scripts/anowine/test_wine_tokens.py`, `scripts/anowine/wine-allowlist.txt`
- Modify: `.github/workflows/AnoEngine.yml` (job `check`: boot a prefix with our build, run the inventory), `spikes/REPORT.md`

**Interfaces:**
- Consumes: artifact `ano-engine` (Task 2).
- Produces:
  - `wine_tokens.py ROOT... --out FILE.tsv [--allowlist FILE]`. Exit 0 (an inventory, not a gate) unless the allowlist is malformed (exit 1).
  - A token is a maximal run of `[A-Za-z0-9_]` containing `wine` in any case. Tokens are taken from:
    - path names, symlink names and symlink targets;
    - file contents: ASCII runs of 4 or more printable bytes, and UTF-16LE runs of 4 or more printable characters.
  - TSV columns: `token`, `class`, `count`, `files`, `example`. `class` is one of:
    - `allowlisted:<category>`;
    - `not-wine-candidate`, when an occurrence is spelled exactly `WinE` (`WinExec`, `WinEvent`), or is preceded by a letter, unless the preceding text ends in `lib`;
    - `wine`.
  - `wine-allowlist.txt` (Plan 3c's gate reads it): one entry per line, `token<TAB>category<TAB>reason`, with `#` comments. Categories are exactly `not-wine`, `alias`, `apple`, `license`, `code-only`, `mono-internal`. Tokens are case-sensitive and unique.
  - Functions: `tokens_in_name(name: str) -> list[str]`, `tokens_in_bytes(data: bytes) -> collections.Counter`, `classify_token(token: str, allow: dict) -> str`, `load_allowlist(path: Path) -> dict[str, tuple[str, str]]`, `main(argv) -> int`.

- [ ] **Step 1: Write the failing tests** in `scripts/anowine/test_wine_tokens.py`:
  - `test_name_tokens`: `tokens_in_name("winecfg.exe") == ["winecfg"]`; `tokens_in_name("libwine.dylib") == ["libwine"]`; `tokens_in_name("wine-mono-11.3.0") == ["wine"]`.
  - `test_ascii_and_utf16`: bytes `b"\x00__wine_unix_call\x00"` plus `"Wine builtin".encode("utf-16-le")` give counts `{"__wine_unix_call": 1, "Wine": 1}`.
  - `test_short_runs_ignored`: `b"wine"` alone (4 bytes) counts; `b"win"` does not.
  - `test_not_wine_candidates`: `WinExec`, `SetWinEventHook` and `twine` → `not-wine-candidate`; `WINEPREFIX`, `libwine` and `__wine_unix_call` → `wine`.
  - `test_allowlist`: a valid file loads, and `classify_token("WinExec", allow) == "allowlisted:not-wine"`. An unknown category, a missing reason or a duplicate token → `ValueError` naming the line number.

- [ ] **Step 2: Push and watch them fail** (`AnoWine Hygiene`, without `[skip ci]`).
  Expected: `ModuleNotFoundError: No module named 'wine_tokens'`.

- [ ] **Step 3: Implement `wine_tokens.py`** to the interface above. Read files in 1 MiB chunks with an overlap, so large DLLs do not load whole and no run is cut at a chunk edge. Skip directories' contents behind symlinks (list the link, do not follow it).

- [ ] **Step 4: Run the tests to verify they pass** (push, watch `AnoWine Hygiene`).
  Expected: the 5 new tests pass.

- [ ] **Step 5: Inventory in CI.** In job `check`, after the comparison:
  - boot a prefix from our build: `WINEPREFIX=$RUNNER_TEMP/prefix DYLD_FALLBACK_LIBRARY_PATH=ours/Libraries/Wine/lib WINEDLLOVERRIDES="mscoree=d;mshtml=d" ours/Libraries/Wine/bin/wine64 wineboot --init`, then `wineserver -w`;
  - run `wine_tokens.py ours/Libraries "$RUNNER_TEMP/prefix" --allowlist scripts/anowine/wine-allowlist.txt --out tokens.tsv`;
  - upload artifact `wine-tokens`.

  Commit an empty allowlist (header comment only) first. Push with `[skip ci]`, then dispatch with `-f engine_run=<the green Task 2 run ID>`.
  Expected: `tokens.tsv` produced.

- [ ] **Step 6: Seed the allowlist.** Read every `not-wine-candidate` row of `tokens.tsv`. Add each one that does not refer to Wine to `wine-allowlist.txt` as `not-wine`, with a reason (for example `WinExec	not-wine	Windows API WinExec (Win + Exec)`). A candidate that does refer to Wine stays out. Ledger the count of each, and name every candidate kept out. Run the inventory again (with `engine_run`).
  Expected: every row left as `not-wine-candidate` is one the ledger names as referring to Wine; the rest are `wine` or `allowlisted:not-wine`.

- [ ] **Step 7: Report and commit.** Add to the Plan 3b section of `spikes/REPORT.md`: distinct tokens and total occurrences, split runtime against bottle and ASCII against UTF-16; the 20 most frequent tokens; the allowlist size.
  ```bash
  git add scripts/anowine/wine_tokens.py scripts/anowine/test_wine_tokens.py scripts/anowine/wine-allowlist.txt .github/workflows/AnoEngine.yml spikes/REPORT.md
  git commit -m "feat: inventory every wine token in the engine and a new bottle; seed the not-Wine allowlist"
  ```

### Task 4: The D3DMetal names script for the owner's Mac

**Files:**
- Create: `scripts/anowine/list-gptk-wine-names.sh` (mode 755), `scripts/anowine/test-list-gptk-wine-names.sh` (mode 755)
- Modify: `.github/workflows/AnoWineHygiene.yml` (run the test), `docs/anowine/TESTING-ON-M2.md`, workspace `CLAUDE.md`

**Interfaces:**
- Produces:
  - `list-gptk-wine-names.sh [store-dir]`. The default store is `~/Library/Application Support/io.github.highstormpvp.Ano/D3DMetal`, the importer's pristine copy of Apple's payload (`GPTKImporter.storeFolder`).
  - It uses only what macOS has without developer tools: `bash`, `find`, `perl`.
  - It writes to stdout and to `~/Desktop/ano-gptk-wine-names.txt`.
  - Output: a header (the date and the store's file count); one line per path or symlink whose name or target contains "wine"; then, for every regular file, one line per distinct string containing "wine" (any case): `<relpath>\t<ascii|utf16>\t<count>\t<string>`, where the string is the whole printable run, cut at 200 characters.
  - It exits 1 with a plain message if the store does not exist ("No Game Porting Toolkit has been imported in Ano").

- [ ] **Step 1: Write the failing test** `test-list-gptk-wine-names.sh`. It builds a fake store in a temp dir:
  - `lib/external/libd3dshared.dylib` holding the ASCII run `___wine_unix_call_dispatcher` twice;
  - `lib/wine/x86_64-windows/d3d12.dll` holding `Wine builtin DLL` (ASCII) and `WineD3D` (UTF-16LE);
  - a symlink `lib/wine/x86_64-unix/d3d12.so → ../../external/libd3dshared.dylib`.

  It runs the script with that store and `HOME` set to the temp dir. It asserts these exact lines:
  - `lib/external/libd3dshared.dylib\tascii\t2\t___wine_unix_call_dispatcher`;
  - `lib/wine/x86_64-windows/d3d12.dll\tascii\t1\tWine builtin DLL`;
  - `lib/wine/x86_64-windows/d3d12.dll\tutf16\t1\tWineD3D`;
  - one line for the symlink;
  - `$HOME/Desktop/ano-gptk-wine-names.txt` exists.

  A missing store must give exit 1. Add a step to `AnoWineHygiene.yml`: `bash scripts/anowine/test-list-gptk-wine-names.sh`.

- [ ] **Step 2: Push and watch it fail** (`AnoWine Hygiene`).
  Expected: the new step fails because `list-gptk-wine-names.sh` does not exist.

- [ ] **Step 3: Implement `list-gptk-wine-names.sh`** to the interface. A perl one-pass scanner per file finds ASCII runs and UTF-16LE runs of 4 or more printable characters that contain "wine".

- [ ] **Step 4: Run the test to verify it passes** (push, watch `AnoWine Hygiene`).
  Expected: green.

- [ ] **Step 5: Deliver and document.**
  - Attach the script to the `ano-test-8` pre-release: `gh release upload ano-test-8 scripts/anowine/list-gptk-wine-names.sh -R HighStormPVP/AnoWine`. This is the pre-approved test-build channel.
  - Add a section "## D3DMetal names (only if you have imported the Game Porting Toolkit)" to `TESTING-ON-M2.md`: download the script from that release, run `bash ~/Downloads/list-gptk-wine-names.sh`, and send back `ano-gptk-wine-names.txt` from the Desktop.
  - Update the workspace `CLAUDE.md` status: Plan 3b done, the build workflow, and that the D3DMetal names wait on the owner.
  ```bash
  git add scripts/anowine/list-gptk-wine-names.sh scripts/anowine/test-list-gptk-wine-names.sh .github/workflows/AnoWineHygiene.yml docs/anowine/TESTING-ON-M2.md
  git commit -m "feat: list-gptk-wine-names.sh shows which Wine names Apple's D3DMetal uses"
  ```
