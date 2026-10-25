# AnoWine Plan 1 — Fork, Feasibility Spikes, Rebrand, Renamed Runtime

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the AnoWine fork, prove (or disprove) the proxy feature's three risky mechanisms on real macOS runners, then ship an installable, rebranded AnoWine test build with renamed Wine programs that the owner can run on their M2 Air.

**Architecture:** AnoWine is a GitHub fork of frankea/Whisky. All compiling and testing happens on GitHub Actions `macos-15` runners (the dev machine is Windows). Feasibility spikes are throwaway C probes run by a dedicated workflow; their results gate the rest of this plan and shape Plan 2 (the proxy feature itself). Rebrand changes are kept minimal and mostly in new files so upstream merges stay easy.

**Tech Stack:** Swift / SwiftUI / Xcode (upstream), C (clang `-arch x86_64` dylibs, MinGW-w64 for a Windows probe `.exe`), bash, Python 3, GitHub Actions, `gh` CLI.

**Spec:** `docs/superpowers/specs/2026-10-25-anowine-design.md`

**Plan 2 (proxy feature: interposer, helper, sandbox launch path, VLESS/XUDP, UI)** is written after Task 6's gate, from the spike report. Not in scope here.

## Global Constraints

- Upstream: `https://github.com/frankea/Whisky`, branch `main`. GPL-3; keep `LICENSE` and upstream credits.
- Fork: `HighStormPVP/AnoWine` (public). Local clone: `C:\Users\Aid\Documents\CLAUDE IDEAS nobackup\AnoWine\repo`.
- Bundle ID prefix: `io.github.highstormpvp.AnoWine`. URL scheme: `anowine`. App name: `AnoWine`.
- Renamed programs: `wine64` → `anowine`, `wineserver` → `anowine-server`. Nothing deeper is renamed.
- Base runtime: frankea release `v3.1.1`, asset `Libraries.tar.gz`, SHA-256 `01f3a1b43b98065fe20c529c1023b61dd79a6d2ad93bba6040865f646481ccf3`. AnoWine runtime version: `3.1.2` (tag `v3.1.2`).
- Keep internal names (`WhiskyKit`, `Wine`, `WhiskyWineInstaller`, logger subsystems, notification names). Prefer new files under `WhiskyKit/Sources/WhiskyKit/AnoWine/` and `scripts/anowine-*`; edits to upstream files are one-line substitutions where possible.
- Scripts must not depend on the current directory: resolve absolute paths from `$(cd "$(dirname "$0")" && pwd)` or `$GITHUB_WORKSPACE`.
- Windows checkout hygiene: `core.autocrlf=false`; `.gitattributes` forces LF for `*.sh *.c *.h *.sb *.py *.yml *.swift *.pbxproj *.plist`; new scripts get `git update-index --chmod=+x`.
- Verification = a green GitHub Actions run (`gh run watch --exit-status <id>`). Nothing is "done" on a local claim.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Outward-facing actions (creating the fork, enabling Pages, publishing a release) are confirmed with the owner at the moment they run.

## Review Focus

1. **CRLF or missing exec bit from the Windows checkout** silently breaks every shell script on macOS → Task 1 adds a CI guard that fails on `\r` in scripts or a non-executable `scripts/anowine-*.sh` / `spikes/**/*.sh`.
2. **Sparkle accepting frankea's updates** (their feed + their EdDSA key) would overwrite AnoWine with Whisky → Task 7 adds a CI check that the built `Info.plist` contains no `frankea`/`com.franke` and no `SUPublicEDKey`.
3. **AnoWine sharing Whisky's data folder** (`~/Library/Application Support/<bundle id>`) would corrupt the owner's Whisky bottles → Task 7's CI check asserts the built `CFBundleIdentifier` is exactly `io.github.highstormpvp.AnoWine`.
4. **A wrong SHA-256 in the Pages plist blocks every first-run install** → Task 11's workflow computes the digest from the uploaded asset and fails if `dist/pages/WhiskyWineVersion.plist` disagrees.
5. **A runtime that still has only `wine64`** (old download, partial install) must be treated as "not installed" and re-downloaded, not crash at launch → Task 10 adds `testRuntimeWithOnlyOriginalNamesIsNotPresent`.

---

### Task 1: Fork, clone, repo hygiene, baseline CI

**Files:**
- Create: `.gitattributes`
- Create: `.github/workflows/AnoWineHygiene.yml`
- Create: `docs/superpowers/specs/2026-10-25-anowine-design.md`, `docs/superpowers/plans/2026-10-25-anowine-plan1-foundation.md` (copied from the project folder)

**Interfaces:**
- Produces: the fork at `HighStormPVP/AnoWine` with Actions enabled; clone at the path in Global Constraints.

- [ ] **Step 1: Confirm with owner, then fork.** `gh repo fork frankea/Whisky --fork-name AnoWine --clone=false`; then `git clone https://github.com/HighStormPVP/AnoWine.git "C:\Users\Aid\Documents\CLAUDE IDEAS nobackup\AnoWine\repo"`; in the clone `git config core.autocrlf false` and `git remote add upstream https://github.com/frankea/Whisky.git`.
- [ ] **Step 2: Enable Actions on the fork.** `gh api -X PUT repos/HighStormPVP/AnoWine/actions/permissions -F enabled=true -f allowed_actions=all`. Disable workflows that need upstream secrets or target upstream infrastructure: `gh workflow disable` for `Crowdin`, `UpdateHomebrewTap`, `AutoAssign`, `TriageCommands` (disable, don't delete — keeps merges clean).
- [ ] **Step 3: Add `.gitattributes`** with the LF rules from Global Constraints; copy the spec and this plan into `docs/superpowers/`.
- [ ] **Step 4: Write the hygiene guard `AnoWineHygiene.yml`** (ubuntu-latest, on push/PR to `main`): fail if `grep -rlI $'\r' -- '*.sh' '*.c' '*.sb' '*.py'` finds anything outside `.git`, or if any `scripts/anowine-*.sh` / `spikes/**/*.sh` lacks the exec bit (`git ls-files -s` mode `100755`).
- [ ] **Step 5: Push and verify baseline.** `git push origin main`; `gh run watch --exit-status` on the `CI` run and the `AnoWineHygiene` run. Expected: both green — upstream builds/tests pass unchanged on our fork. If upstream CI is red on its own, record which job and continue (not ours to fix).
- [ ] **Step 6: Commit** (`chore: AnoWine fork hygiene and design docs`).

---

### Task 2: Spike harness + injection probe (go/no-go #1)

**Files:**
- Create: `spikes/netprobe/netprobe.c` (Windows console program)
- Create: `spikes/interposer/logshim.c`
- Create: `spikes/lib.sh` (shared setup: download+verify runtime, install Rosetta, boot prefix, start echo servers)
- Create: `spikes/echo_servers.py`
- Create: `spikes/probe_injection.sh`
- Create: `.github/workflows/Spikes.yml`

**Interfaces:**
- Produces: `netprobe.exe` CLI used by Tasks 3–5:
  - `netprobe dns <host>` → prints one resolved IPv4 per line, exit 0/1
  - `netprobe tcp <host> <port>` → connect, send `PING\n`, expect `PING\n` echoed, exit 0/1
  - `netprobe udp <ip1> <port1> <ip2> <port2>` → send `U1` to first and `U2` to second from **one** socket, expect both echoed within 3 s, print `from <ip>:<port>` per reply, exit 0/1
- Produces: `liblogshim.dylib` — `DYLD_INTERPOSE` wrappers for `socket, connect, bind, sendto, sendmsg, recvfrom, recvmsg, getaddrinfo` that append `<pid> <getprogname()> <func> <family>/<type> <addr:port|host>` to the file named by `ANOWINE_SPIKE_LOG`, then call the real function.
- Produces: `spikes/lib.sh` functions `spike_fetch_runtime <dir>` (downloads frankea v3.1.1, verifies the SHA-256 from Global Constraints, unpacks to `<dir>/Libraries`), `spike_boot_prefix <wine_bin> <prefix>` (runs `wineboot -i`, then `wineserver -k` so later runs start a fresh server that inherits the probe env), `spike_start_echo` (TCP echo `127.0.0.1:7001` and `127.0.0.1:7004`; UDP echo `127.0.0.1:7002` and `127.0.0.2:7003` — `sudo ifconfig lo0 alias 127.0.0.2 up` first).
- Produces: workflow job outputs uploaded as artifact `spike-logs` (all `ANOWINE_SPIKE_LOG` files + `codesign` output).

- [ ] **Step 1: Write `netprobe.c`** (Winsock2, `getaddrinfo`, blocking sockets are fine). Build line used in CI: `x86_64-w64-mingw32-gcc -O2 -o netprobe.exe netprobe.c -lws2_32` (`brew install mingw-w64`).
- [ ] **Step 2: Write `logshim.c`.** Build: `clang -arch x86_64 -dynamiclib -O2 -o liblogshim.dylib logshim.c`. Open the log with `O_APPEND` per write so lines from several processes interleave safely.
- [ ] **Step 3: Write `probe_injection.sh`** asserting, in order:
  1. `codesign -dv --verbose=4` on `Wine/bin/wine64` and `Wine/bin/wineserver` → saved to log; print whether flags include `runtime` or `library-validation`.
  2. With `DYLD_INSERT_LIBRARIES=<abs>/liblogshim.dylib` and a fresh server, `wine64 netprobe.exe tcp 127.0.0.1 7001` exits 0.
  3. The log contains a `connect` line with `127.0.0.1:7001`. Print the distinct `getprogname()` values per function as a table (this answers spec §9 "which process calls connect/getaddrinfo").
  4. `wine64 netprobe.exe dns example.com` exits 0 and the log has a `getaddrinfo` line naming `example.com`.
  5. `wine64 netprobe.exe udp 127.0.0.1 7002 127.0.0.2 7003` exits 0; record which process logs `socket`/`sendto`/`recvfrom` for `SOCK_DGRAM`.
  Exit non-zero on any failed assertion.
- [ ] **Step 4: Write `Spikes.yml`** — triggers: `push` with `paths: ['spikes/**', '.github/workflows/Spikes.yml']` and `workflow_dispatch`; `runs-on: macos-15`; steps: `softwareupdate --install-rosetta --agree-to-license || true`, `brew install mingw-w64`, build both artifacts, run `probe_injection.sh`, upload `spike-logs` with `if: always()`.
- [ ] **Step 5: Push and watch.** `gh run watch --exit-status`. Expected: PASS. If step 3.2/3.3 fails because injection is refused, **stop the plan here** and go straight to Task 6 with result "injection: NO-GO".
- [ ] **Step 6: Commit** (`spike: injection probe`).

---

### Task 3: Renamed-programs probe

**Files:**
- Create: `spikes/probe_rename.sh`
- Modify: `.github/workflows/Spikes.yml` (add step)

**Interfaces:**
- Consumes: `spikes/lib.sh`, `netprobe.exe` (Task 2).
- Produces: the exact rename recipe Task 11's repack script will use (recorded in the spike log).

- [ ] **Step 1: Write `probe_rename.sh`**: copy the runtime, log `ls -la Wine/bin` (record whether `wine64` is a real file or a symlink to `wine`, and every other binary present). Rename the real `wine64` executable to `anowine` (if `wine64` is a symlink, rename its target and recreate nothing under the old names) and `wineserver` to `anowine-server`. Set `WINESERVER=<abs>/Wine/bin/anowine-server`. Assert:
  1. `anowine wineboot -i` exits 0 on a new prefix.
  2. After starting a persistent server (`anowine-server -p 30`) and running `anowine netprobe.exe dns example.com`, `ps -axo comm` lists `anowine-server` and no process named `wineserver` or `wine64`.
  3. The netprobe run exits 0.
  4. `WINE=<abs>/anowine WINESERVER=<abs>/anowine-server bash <winetricks> list-installed` (winetricks from `Libraries/` in the repo) exits 0.
- [ ] **Step 2: Add to `Spikes.yml`, push, watch.** Expected: PASS. A failure is not a plan stopper: record "rename: keep original names" (spec §7) and Task 10/11 skip the rename.
- [ ] **Step 3: Commit** (`spike: renamed wine programs probe`).

---

### Task 4: Sandbox + DYLD shim probe (go/no-go #2)

**Files:**
- Create: `spikes/sandbox/net-lockdown.sb`
- Create: `spikes/sandbox/shim.c`
- Create: `spikes/probe_sandbox.sh`
- Modify: `.github/workflows/Spikes.yml`

**Interfaces:**
- Consumes: Task 2 artifacts and `lib.sh`.
- Produces: `shim` — `shim <program> [args…]`: copies env `ANOWINE_INSERT` into `DYLD_INSERT_LIBRARIES`, unsets `ANOWINE_INSERT`, `execv`s `<program>`. Build universal: `clang -arch arm64 -arch x86_64 -O2 -o shim shim.c`.
- Produces: a working SBPL profile Plan 2 will generate per launch.

- [ ] **Step 1: Write `net-lockdown.sb`** taking the allowed port as a parameter (`(param "ALLOW_PORT")`, passed with `sandbox-exec -D ALLOW_PORT=7001`): `(version 1) (allow default) (deny network-outbound) (allow network-outbound (remote unix-socket)) (allow network-outbound (remote ip (string-append "localhost:" (param "ALLOW_PORT"))))`.
- [ ] **Step 2: Write `shim.c`.**
- [ ] **Step 3: Write `probe_sandbox.sh`**; all runs use `sandbox-exec -D ALLOW_PORT=7001 -f net-lockdown.sb <abs>/shim <abs>/wine64 …` with `ANOWINE_INSERT=<abs>/liblogshim.dylib`, after `wineserver -k` so the server is born inside the sandbox. Assert:
  1. `netprobe tcp 127.0.0.1 7001` exits 0 (Wine works sandboxed; allowed port reachable).
  2. `netprobe tcp 127.0.0.1 7004` exits 1 (other local ports blocked).
  3. `netprobe tcp 1.1.1.1 443` exits 1 (internet blocked).
  4. `netprobe udp 127.0.0.1 7002 127.0.0.2 7003` exits 1 (UDP blocked).
  5. The log has lines from both the loader and the server process (DYLD survived the SIP-protected `sandbox-exec` via the shim; server inherited it).
  6. Control: without `sandbox-exec`, assertion 3 exits 0 (proves the block came from the sandbox).
- [ ] **Step 4: Add to `Spikes.yml`, push, watch.** Expected: PASS. If 1 or 5 fails, record "kill switch: fallback per spec §10 (ship without kill switch)" — not a plan stopper.
- [ ] **Step 5: Commit** (`spike: sandbox kill-switch probe`).

---

### Task 5: UDP substitution probe (go/no-go #3)

**Files:**
- Create: `spikes/interposer/udpshim.c`
- Create: `spikes/udp_relay.py`
- Create: `spikes/probe_udp.sh`
- Modify: `.github/workflows/Spikes.yml`

**Interfaces:**
- Consumes: Task 2 (`netprobe`, which process creates/uses UDP sockets), Task 4 (`shim`, `net-lockdown.sb`).
- Produces: a yes/no on spec §9's hardest risk, and the list of socket calls Wine actually makes on UDP fds (input to Plan 2's interposer design).

- [ ] **Step 1: Write `udpshim.c`** (x86_64 dylib, also logs like `logshim`). Mechanism under test:
  - `socket(AF_INET|AF_INET6, SOCK_DGRAM, …)` → create `AF_UNIX`/`SOCK_DGRAM`, bind it to `/tmp/anowine-udp/<pid>-<counter>`, connect it to the relay path in `ANOWINE_UDP_RELAY`, return that fd.
  - Recognise a substituted fd **by its bound path prefix** (`getsockname` on the fd → `sun_path` starts with `/tmp/anowine-udp/`), never by an in-process table — fds are created in one Wine process and passed to another.
  - `sendto`/`sendmsg` on a substituted fd → prepend a header `[u8 family][u16 port BE][16-byte addr]` and send to the relay; `recvfrom`/`recvmsg` → strip it and fill the source address; `getsockname` → fake `0.0.0.0:<stable fake port>`; `bind`/`connect` with an IP address → record locally, return 0; `setsockopt`/`getsockopt` at `IPPROTO_IP`/`IPPROTO_IPV6`/`SO_BROADCAST` → return 0. Log every other call made on a substituted fd.
- [ ] **Step 2: Write `udp_relay.py`**: listens on the Unix datagram path, unwraps the header, sends real UDP to the destination, wraps replies with the true source, and returns them to the sender's path. It runs **outside** the sandbox.
- [ ] **Step 3: Write `probe_udp.sh`**: start the relay; run sandboxed (Task 4 profile, `ALLOW_PORT=7001`) with `ANOWINE_INSERT=<abs>/libudpshim.dylib`. Assert:
  1. `netprobe udp 127.0.0.1 7002 127.0.0.2 7003` exits 0 and prints `from 127.0.0.1:7002` and `from 127.0.0.2:7003` (both destinations, correct sources).
  2. The relay logged both datagrams (the traffic went through it, not around it — the sandbox forbids direct UDP anyway).
  3. Print the "other calls on substituted fds" list from the log.
- [ ] **Step 4: Add to `Spikes.yml`, push, watch.** Expected: PASS. A failure here is reported, not fixed in this plan: Plan 2 then either redesigns UDP or the owner decides to ship TCP+DNS first.
- [ ] **Step 5: Commit** (`spike: UDP substitution probe`).

---

### Task 6: Spike report — GATE

**Files:**
- Create: `spikes/REPORT.md`

- [ ] **Step 1: Write `REPORT.md`** from the `spike-logs` artifact of the latest green (or final) run: for each of injection / rename / sandbox / UDP — result (GO / NO-GO / fallback), the evidence lines, and the process-per-call table from Task 2. Link the Actions run.
- [ ] **Step 2: Commit and push** (`spike: feasibility report`).
- [ ] **Step 3: STOP. Present the report to the owner.** Do not start Task 7 until the owner says to continue. If injection was NO-GO, the owner decides whether AnoWine continues as a rebrand without the proxy.

---

### Task 7: App identity rebrand

**Files:**
- Modify: `Whisky.xcodeproj/project.pbxproj` (every `PRODUCT_BUNDLE_IDENTIFIER`; `PRODUCT_NAME` for the `Whisky` app target only)
- Modify: `Whisky/Info.plist` (`CFBundleURLName`, `CFBundleURLSchemes`, `SUFeedURL`, remove `SUPublicEDKey`, add `SUEnableAutomaticChecks` = `false`)
- Modify: `Whisky/Utils/QuickLaunch.swift` (scheme literal)
- Modify: `WhiskyKit/Sources/WhiskyKit/Utils/DistributionConfig.swift`, `WhiskyKit/Tests/WhiskyKitTests/DistributionConfigTests.swift`
- Modify: issue/repo links in `Whisky/Views/WhiskyApp.swift`, `WhiskyKit/Sources/WhiskyKit/WhiskyWine/WhiskyWineSetupDiagnostics.swift`, `WhiskyKit/Sources/WhiskyKit/Wine/WinePrefixDiagnostics.swift`
- Modify: `.github/workflows/CI.yml` (add one verification step to the `build` job)

**Interfaces:**
- Produces: `DistributionConfig.baseURL == "https://highstormpvp.github.io/AnoWine"`, `releasesBaseURL == "https://github.com/HighStormPVP/AnoWine/releases/download"` (used by Task 11).

- [ ] **Step 1: Update `DistributionConfigTests`** to expect the two URLs above and `versionPlistURL == "https://highstormpvp.github.io/AnoWine/WhiskyWineVersion.plist"`.
- [ ] **Step 2: Push; confirm the `Run Tests` job FAILS** on those assertions.
- [ ] **Step 3: Apply the identity changes.** Bundle IDs: `com.franke.Whisky` → `io.github.highstormpvp.AnoWine`; `com.franke.WhiskyCmd` → `io.github.highstormpvp.AnoWineCmd`; `com.franke.Whisky.WhiskyThumbnail` → `io.github.highstormpvp.AnoWine.Thumbnail`; `com.franke.WhiskyUITests` → `io.github.highstormpvp.AnoWineUITests`. App `PRODUCT_NAME = AnoWine`. URL scheme `anowine`. `SUFeedURL` = `https://highstormpvp.github.io/AnoWine/appcast.xml`. Repo/issue links → `https://github.com/HighStormPVP/AnoWine` (`/issues`). Leave logger subsystem and notification-name literals alone.
- [ ] **Step 4: Add CI step "Verify AnoWine identity"** to the `build` job, using the same `$app` resolution as the existing resources step: assert `$app` ends with `AnoWine.app`; `defaults read "$app/Contents/Info" CFBundleIdentifier` equals `io.github.highstormpvp.AnoWine`; `grep -c 'frankea\|com.franke' "$app/Contents/Info.plist"` is `0`; `/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey'` fails (key absent).
- [ ] **Step 5: Push; watch CI.** Expected: `build`, `ui-test`, `Run Tests` all PASS.
- [ ] **Step 6: Commit** (`feat: AnoWine app identity`).

Sparkle stays switched off here (no key, no automatic checks). AnoWine's own EdDSA key, appcast and release signing belong to the later release plan.

---

### Task 8: Visible strings rebrand

**Files:**
- Create: `scripts/anowine-rebrand-strings.py`
- Modify: `Whisky/Localizable.xcstrings` (generated by the script)
- Modify: `.github/workflows/AnoWineHygiene.yml` (add check)

**Interfaces:**
- Produces: `python3 scripts/anowine-rebrand-strings.py [--check] <path-to-xcstrings>` — rewrites **values only, never keys**, in every localization: `WhiskyWine` → `Wine runtime` (in `en`; other languages: `WhiskyWine` → `Wine`), then `Whisky` → `AnoWine`. For keys whose source text contains `Whisky` and that have no `en` localization, add an `en` `stringUnit` with the rewritten value. Idempotent. `--check` exits 1 if a rewrite would change anything. Re-run after every upstream merge.

- [ ] **Step 1: Write the script's self-test** `scripts/test_anowine_rebrand_strings.py` (stdlib `unittest`, run in the hygiene workflow): a minimal xcstrings fixture where key `"Welcome to Whisky"` has `fr` value `"Bienvenue dans Whisky"` and key `"Download WhiskyWine"` has no `en`; assert output `en` = `"Welcome to AnoWine"`, `fr` = `"Bienvenue dans AnoWine"`, `en` for the second = `"Download Wine runtime"`, keys unchanged, second run makes no change.
- [ ] **Step 2: Run it in CI; confirm FAIL** (script missing).
- [ ] **Step 3: Implement the script; run it locally on `Whisky/Localizable.xcstrings`** (Python works on Windows; write with `ensure_ascii=False`, 2-space indent, `separators=(',', ' : ')` to match Xcode's format — check the diff touches only values).
- [ ] **Step 4: Grep remaining user-visible literals** outside the catalog: `grep -rn '"[^"]*Whisky[^"]*"' Whisky WhiskyKit/Sources --include=*.swift` and change only strings shown to users (e.g. `DiscordPresence.swift` `largeText: "Whisky"` → `"AnoWine"`). Leave identifiers, subsystems, file names.
- [ ] **Step 5: Add `--check` to the hygiene workflow; push; watch** hygiene + CI (the existing translation-completeness check in `build` must still pass). Expected: PASS.
- [ ] **Step 6: Commit** (`feat: AnoWine branding in UI strings`).

---

### Task 9: Placeholder icon

**Files:**
- Create: `scripts/anowine-make-icon.py`
- Modify: `Whisky/Assets.xcassets/AppIcon.appiconset/*.png` (same filenames and sizes as existing `Contents.json` entries)

- [ ] **Step 1: Implement `anowine-make-icon.py`** (Pillow, available locally): reads `Contents.json`, renders a simple 1024×1024 mark (rounded square, solid colour, "AW" monogram) and writes every listed size/scale with the existing filenames.
- [ ] **Step 2: Run it; verify** each PNG's pixel size matches `size × scale` from `Contents.json` (`python -c` check printed in the step output).
- [ ] **Step 3: Push; watch CI `build`.** Expected: PASS (no asset catalog warnings-as-errors).
- [ ] **Step 4: Commit** (`feat: placeholder AnoWine icon`). The owner can replace the art later.

---

### Task 10: Use the renamed programs in the app

Skip this task (and the rename in Task 11) if Task 6 recorded "rename: keep original names".

**Files:**
- Create: `WhiskyKit/Sources/WhiskyKit/AnoWine/AnoWineRuntime.swift`
- Create: `WhiskyKit/Tests/WhiskyKitTests/AnoWineRuntimeTests.swift`
- Modify (one-line substitutions): `WhiskyKit/Sources/WhiskyKit/Wine/Wine.swift:92,94` and the terminal aliases at `:675-685`; `WhiskyKit/Sources/WhiskyKit/Wine/Wine+ProcessManagement.swift:46`; `WhiskyKit/Sources/WhiskyKit/WhiskyWine/WhiskyWineInstaller.swift:129`; `WhiskyKit/Sources/WhiskyKit/Troubleshooting/Checks/ProcessRunningCheck.swift:33`; `Whisky/Utils/Winetricks+Install.swift:128`; `Whisky/Utils/Winetricks+InstalledVerbs.swift:51`; `Whisky/Utils/Winetricks.swift:131`
- Modify: `WhiskyKit/Sources/WhiskyKit/Wine/WineEnvironment.swift` (base layer of both wine and wineserver environments)
- Modify: tests that assert `wine64` (`ProgramExtensionTests.swift:68,103,157`, `ProgramLaunchPreparationTests.swift:125`, and any others the CI run surfaces)

**Interfaces:**
- Produces:
  ```swift
  public enum AnoWineRuntime {
      public static let loaderName = "anowine"
      public static let serverName = "anowine-server"
      public static var loaderURL: URL { get }   // WhiskyWineInstaller.binFolder/loaderName
      public static var serverURL: URL { get }   // WhiskyWineInstaller.binFolder/serverName
  }
  ```
  Every launch environment gets `WINESERVER = AnoWineRuntime.serverURL.path(percentEncoded: false)` in the `.base` layer. Winetricks gets `WINE = loaderName` and `WINESERVER` the same full path. Terminal aliases point at `anowine` (keep alias names `wine`, `winecfg`, … as they are).

- [ ] **Step 1: Write `AnoWineRuntimeTests`:**
  - `testNames` — `loaderName == "anowine"`, `serverName == "anowine-server"`.
  - `testWineBinaryUsesLoaderName` — `Wine.wineBinary.lastPathComponent == "anowine"`.
  - `testEnvironmentSetsWineserver` — `Wine.constructWineEnvironment(for: <temp bottle>)["WINESERVER"]` ends with `/Libraries/Wine/bin/anowine-server`.
  - `testRuntimeWithOnlyOriginalNamesIsNotPresent` — temp library folder containing a version plist and `Wine/bin/wine64` only → `WhiskyWineInstaller.isRuntimePresent(inLibraryFolder:) == false`; adding `Wine/bin/anowine` → `true`.
  (Use whatever temp-bottle helper existing tests use, e.g. in `EnvironmentVariablesTests.swift`.)
- [ ] **Step 2: Push; confirm FAIL.**
- [ ] **Step 3: Implement `AnoWineRuntime.swift` and the substitutions;** update the tests listed above from `wine64` to `anowine`.
- [ ] **Step 4: Push; watch CI.** Expected: all jobs PASS.
- [ ] **Step 5: Commit** (`feat: launch renamed anowine programs`).

---

### Task 11: AnoWine runtime v3.1.2 — repack, publish, Pages

**Files:**
- Create: `scripts/anowine-repack-runtime.sh`
- Create: `.github/workflows/AnoWineRuntime.yml`
- Modify: `dist/pages/WhiskyWineVersion.plist` (version 3.1.2, new `sha256`)
- Modify: `docs/DEPENDENCIES.md` (add an "AnoWine runtime v3.1.2" row: upstream 3.1.1 + renamed programs, new digest)

**Interfaces:**
- Consumes: Task 3's rename recipe; Task 7's `DistributionConfig` URLs.
- Produces: `scripts/anowine-repack-runtime.sh <out-dir>` → downloads frankea `v3.1.1` `Libraries.tar.gz`, verifies the Global Constraints digest (fail closed), applies the rename, sets the inner plist version to 3.1.2, repacks with `COPYFILE_DISABLE=1 tar --no-xattrs -czf`, prints `SHA-256: <digest>`. Asserts after repack: `Libraries/Wine/bin/anowine` and `anowine-server` exist and are executable; `wine64` and `wineserver` do not exist.

- [ ] **Step 1: Write the script** (model it on `scripts/assemble-runtime.sh`'s verify/unpack/plist/repack steps).
- [ ] **Step 2: Write `AnoWineRuntime.yml`** (`workflow_dispatch` + push on the script/workflow paths; `macos-15`; `permissions: contents: write`): run the script, then smoke-test the produced archive — unpack, `WINESERVER=… anowine wineboot -i` exits 0 — and upload `Libraries.tar.gz` as a workflow artifact. A separate job, gated on `workflow_dispatch` input `publish: true`, runs `gh release create v3.1.2 --title "AnoWine Wine runtime v3.1.2" <dir>/Libraries.tar.gz` (asset filename must be exactly `Libraries.tar.gz`).
- [ ] **Step 3: Push; watch the build/smoke job.** Expected: PASS.
- [ ] **Step 4: Confirm with owner, then publish:** `gh workflow run AnoWineRuntime.yml -f publish=true`; watch it.
- [ ] **Step 5: Write the digest check:** add a job to `AnoWineRuntime.yml` (and run it on push of `dist/pages/**`) that downloads the `v3.1.2` asset, computes its SHA-256, and fails unless it equals the `sha256` in `dist/pages/WhiskyWineVersion.plist`. Push; confirm it FAILS against the old plist.
- [ ] **Step 6: Update `WhiskyWineVersion.plist` and `DEPENDENCIES.md`;** push; confirm the digest check PASSES.
- [ ] **Step 7: Confirm with owner, then enable Pages:** `gh api -X POST repos/HighStormPVP/AnoWine/pages -f build_type=workflow`; re-run `Documentation.yml`; verify `curl -fsSL https://highstormpvp.github.io/AnoWine/WhiskyWineVersion.plist` shows version 3.1.2 and the new digest.
- [ ] **Step 8: Commit** (`feat: AnoWine runtime v3.1.2 with renamed programs`).

---

### Task 12: Test build for the M2 Air + owner checklist

**Files:**
- Create: `.github/workflows/AnoWineTestBuild.yml`
- Create: `scripts/anowine-m2-sandbox-check.sh`
- Create: `docs/anowine/TESTING-ON-M2.md`

**Interfaces:**
- Consumes: Task 4's `net-lockdown.sb` (copied into the script as a heredoc — scripts must not depend on the repo being present on the Mac).
- Produces: artifact `AnoWine-test.zip` (Release config, ad-hoc signed `codesign --force --deep -s -`, zipped with `ditto -c -k --keepParent`).

- [ ] **Step 1: Write `AnoWineTestBuild.yml`** (`workflow_dispatch` + push to `main`; `macos-15`): `xcodebuild -scheme Whisky -configuration Release` with signing disabled, ad-hoc sign, verify `codesign --verify --deep AnoWine.app` passes and the Task 7 identity assertions hold, upload `AnoWine-test.zip`.
- [ ] **Step 2: Write `anowine-m2-sandbox-check.sh <bottle-path>`**: kills the bottle's server, then launches the bottle's `Steam.exe` via the installed runtime (`~/Library/Application Support/io.github.highstormpvp.AnoWine/Libraries/Wine/bin/anowine`) under `sandbox-exec` with a profile that is `(allow default)` plus the network rules **but allowing all outbound IP** — so only the sandbox's effect on Metal/GPU/Steam's web helper is tested, not connectivity. Prints what to look for and asks the owner to report: Steam window renders (not black), store page renders, one installed game launches and renders.
- [ ] **Step 3: Write `TESTING-ON-M2.md`** (plain language for the owner): download the artifact from the Actions run; unzip; first launch via System Settings → Privacy & Security → "Open Anyway"; let it install the runtime; create a bottle; install Steam from the app's launcher support; log in; play one game. Then run the sandbox check script and report the three observations. Note: Whisky stays untouched (separate app and data). Also replace the top of `README.md` with a short AnoWine section: what it is, that it's built on frankea/Whisky (GPL-3), and the "Open Anyway" first-launch step.
- [ ] **Step 4: Push; watch the test build.** Expected: PASS and `AnoWine-test.zip` artifact present (`gh run view <id> --json artifacts`).
- [ ] **Step 5: Commit** (`feat: AnoWine test build and M2 checklist`).
- [ ] **Step 6: Hand to owner.** Send the artifact link and `TESTING-ON-M2.md`. The spec's hardware gate (sandbox vs Metal/Steam) is closed only by the owner's report; record it in `spikes/REPORT.md`. Then write Plan 2.
