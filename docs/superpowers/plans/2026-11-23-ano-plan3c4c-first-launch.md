# Ano Plan 3c-4c — first launch

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The first launch of the renamed app removes what earlier Ano versions left with "wine" in its name, carries the user's settings and imported Game Porting Toolkit across the rename, and the owner gets a script for the one trace that needs admin rights; the text the 3c-4b reviews found misleading is fixed.

**Architecture:** Two WhiskyKit units:
- `AppMigrations` runs synchronously before anything reads settings or the GPTK store: it renames and drops defaults keys, and moves the store's `lib/wine` to `lib/ano`.
- `OldTraceCleanup` runs once, in the background: it deletes caches and temp files that Ano 6–8 left in the home folder, `/tmp` and the user cache folder, and never touches a live Wine server.

Each unit is a pure function over injected locations, so tests run in temporary folders. A shell script lists and deletes Rosetta's cached translations of old runtime files; it is the only part that needs `sudo`.

**Tech Stack:** Swift (WhiskyKit, the app), POSIX shell, GitHub Actions (`CI`, `AnoWine Hygiene`).

**Spec:** `docs/superpowers/specs/2026-11-18-ano-full-rename-design.md`:
- decision 3 (old bottles are not converted)
- decision 6 (code-only names stay)
- decision 8 (old traces are cleaned up)
- How 6 ("First launch cleans up old traces")
- the appendix's "On the Mac" table

Roadmap: `docs/superpowers/plans/2026-11-21-ano-plan3c4a-app-runtime.md`, row 3c-4c. Carried items: ledgers `.superpowers/sdd/2026-11-21-ano-plan3c4a-app-runtime/progress.md` and `.superpowers/sdd/2026-11-22-ano-plan3c4b-app-text/progress.md`.

## Global Constraints

- Decision 8, verbatim: "On first launch of the renamed version the app deletes what earlier versions left that it owns and can remove without admin rights (for example `~/.cache/winetricks`, `/tmp/.wine-<uid>`, the `org.winehq.wine` cache folder, old defaults keys). The owner gets a one-off script for what needs admin rights (Rosetta's `/var/db/oah/.../wine*.aot` files)."
- Old bottles are never written (decision 3). Nothing inside a bottle folder is cleaned, including `WinetricksCache.plist` and `winetricks.log`.
- The app never asks for admin rights and never deletes outside the user's home folder, the user's temporary folder, the user cache folder (`confstr(_CS_DARWIN_USER_CACHE_DIR)`) and `/tmp/.wine-<uid>`.
- A Wine server that is running is never disturbed. Its folder `/tmp/.wine-<uid>/server-*` holds a `lock` file that the live server keeps locked with `fcntl` (`F_SETLK`), so the app tests that lock with `F_GETLK`.
- A symlink found at a cleanup path is removed as a link. Its target is never followed.
- The runtime's old `Libraries/Wine` needs no cleanup: installing runtime 5.x swaps the whole `Libraries` folder (`WhiskyWineInstaller.install(from:)`).
- The new defaults key for the update-check opt-out is `checkAnoRuntimeUpdates`. The user's stored choice is carried over, and the update check reads it only after the migration.
- Every literal that names an old trace carries `// old name: <reason>` on its line, so `check_app_text.py` and `check_app_runtime_names.py` stay at 0. No new "wine" may appear anywhere else.
- Kept, by ruling:
  - "Whisky Community" as the GameDB author (attribution of upstream entries);
  - `frankea/Whisky#N` issue references;
  - credits and license text naming Whisky.

  A full "Whisky" text sweep is not part of 3c.
- SwiftLint (120 columns, the GPL header, length limits) and SwiftFormat. `gh -R HighStormPVP/AnoWine`. Push RED and watch it fail before GREEN. Use `[skip ci]` plus a dispatched run. Stage files by path.
- 3c-4c ships nothing; the next app build is 3c-5's.

## Review Focus

1. Another Wine app (CrossOver, the original Whisky, Homebrew `wine`) is running when Ano first launches. Its live server folder in `/tmp/.wine-<uid>` must stay, and only stale ones go. Test: Task 1, `testALiveServerFolderStays`.
2. A user who turned off runtime update checks in Ano 6–8 still has them off after the upgrade, including for the update check the first launch makes. Test: Task 2, `testTheUpdateCheckOptOutIsCarriedOver`, plus the launch order in `AppDelegate`.
3. An Ano-8 user with an imported Game Porting Toolkit keeps D3DMetal without importing it again: the store is renamed, it still counts as verified, and deploy finds its bridges. Test: Task 2, `testAnAno8StoreIsRenamedAndStaysVerified`.
4. A cleanup step that fails (permission denied, file busy) is logged and skipped. It never blocks or crashes the launch, and the cleanup is marked done, so it does not retry on every launch. Test: Task 1, `testAFailedRemovalIsSkippedAndTheRunIsMarkedDone`.
5. A symlink at a cleanup path, for example `~/.cache/winetricks` pointing to an external drive, loses only the link. Test: Task 1, `testASymlinkIsRemovedNotFollowed`.

---

### Task 1: The one-time cleanup of old traces

**Files:**
- Create `WhiskyKit/Sources/WhiskyKit/AnoWine/OldTraceCleanup.swift` and `WhiskyKit/Tests/WhiskyKitTests/OldTraceCleanupTests.swift`.
- Modify `Whisky/AppDelegate.swift`: call it in the background after launch.
- Create `.superpowers/sdd/<plan>/old-traces.md` (the inventory; not in git).

**Interfaces:** Produces:
- `public enum OldTraceCleanup`, with:
  - `static let currentVersion = 1`
  - `static let doneDefaultsKey = "oldTracesCleanupVersion"`
- `public struct OldTraceCleanup.Places: Sendable`, with:
  - `home`, `temporaryFolder`, `userCacheFolder`, `applicationFolder`, `serverRoot: URL`
  - `uid: uid_t`
  - `static var live: Places` (`serverRoot` = `/private/tmp`)
- `static func targets(in places: Places, isServerLive: (URL) -> Bool) -> [URL]`
- `@discardableResult static func clean(_ places: Places, isServerLive: (URL) -> Bool = serverLockIsHeld) -> [URL]` (what it removed)
- `@discardableResult static func runIfNeeded(defaults: UserDefaults = .standard, places: Places = .live) -> [URL]?` (`nil` when it already ran)
- `static func serverLockIsHeld(_ serverFolder: URL) -> Bool`

**The list** (each entry is a literal line with `// old name:`):
- `home/.cache/winetricks`
- `/tmp/.wine-<uid>/server-*` (stale ones only), then `/tmp/.wine-<uid>` itself if it is empty
- `userCacheFolder/org.winehq.wine` and `home/Library/Caches/org.winehq.wine`
- `temporaryFolder/winetricks.*` (folders) and `temporaryFolder/whisky-winetricks-*.sh` (Ano ≤ 8's terminal scripts)
- `applicationFolder/Proxy/bin/ano-loader` when its text says "wine" (Ano 6–8's wrapper; the proxy writes it again when needed, `ProxyEnvironment.installWrapper`)
- plus anything the inventory step adds

- [ ] **Step 1: Inventory.**
  - Read the code at tags `ano-test-6`, `ano-test-7` and `ano-test-8` (`git grep`). List every file, folder and temp file the app, the bundled winetricks or the proxy wrote outside a bottle whose name or (for scripts) text says "wine".
  - Record in `old-traces.md` whether each is on the list above, removed by the runtime swap, inside a bottle (never touched) or needs admin rights (Task 5).
  - Anything new that the app owns and can remove joins the list, as a ledger ruling.

- [ ] **Step 2: Write the failing tests** in `OldTraceCleanupTests.swift`. Each test builds a fake `Places` in a temp folder.
  - `testTheListedTracesAreRemoved`: every entry above is created, then `clean` runs; each is gone, and the files beside them (`home/.cache/other`, `temporaryFolder/keep.txt`, `applicationFolder/Proxy/bin/other`) remain.
  - `testALiveServerFolderStays`: two folders `server-1-2` and `server-3-4` exist, with `isServerLive` true for the first only. The first stays, the second goes, and `.wine-<uid>` stays because it is not empty.
  - `testServerLockIsHeldSeesAnotherProcessesLock`: a child process (`/usr/bin/perl` with `Fcntl`, `F_SETLK` on `<folder>/lock`, then sleep) holds the lock. `serverLockIsHeld` is true while the child runs and false after it is killed. With no `lock` file it is false.
  - `testASymlinkIsRemovedNotFollowed`: `home/.cache/winetricks` is a symlink to `<tmp>/external/winetricks`, which holds a file. After `clean` the link is gone and the target's file still exists.
  - `testAFailedRemovalIsSkippedAndTheRunIsMarkedDone`: one target sits in a folder made read-only (`0o555`). `runIfNeeded` returns the removed others without throwing, and `defaults.integer(forKey: "oldTracesCleanupVersion") == 1`.
  - `testItRunsOnce`: a second `runIfNeeded` returns `nil` and removes nothing new.
  - `testTheWrapperIsRemovedOnlyWhenItSaysWine`: a wrapper whose text is the current `ProxyEnvironment.wrapperScript` stays; one that says `ANO_WINE_DIR` goes.
  - Use a fresh `UserDefaults(suiteName:)` in each test.

  Push (`[skip ci]`), dispatch CI. Expected: these tests fail to compile or fail (the type is missing).
- [ ] **Step 3: Implement `OldTraceCleanup`.**
  - `serverLockIsHeld` opens `lock` read-write and asks `fcntl(F_GETLK)` for a write lock over the whole file. A missing or unopenable file counts as "not held".
  - Removal uses `FileManager.removeItem`, which removes a symlink, not its target. Each failure is logged under category `AnoMigration` and skipped.
  - `runIfNeeded` writes `currentVersion` after `clean` returns, whatever was skipped.
  - `AppDelegate.applicationDidFinishLaunching` calls `Task.detached(priority: .utility) { OldTraceCleanup.runIfNeeded() }`, except under UI tests (`isUITesting`, as `WhiskyApp` uses).
- [ ] **Step 4:** Commit (`[skip ci]`), dispatch CI and Hygiene. Expected: CI is green. In Hygiene, `check_app_text.py` and `check_app_runtime_names.py` print 0.
- [ ] **Step 5:** Ledger the inventory result and rulings.

### Task 2: Settings and the GPTK store across the rename

**Files:**
- Create `WhiskyKit/Sources/WhiskyKit/AnoWine/AppMigrations.swift` and `WhiskyKit/Tests/WhiskyKitTests/AppMigrationsTests.swift`.
- Modify:
  - `WhiskyKit/Sources/WhiskyKit/WhiskyWine/WhiskyWineInstaller+UpdateCheck.swift`: the key becomes `checkAnoRuntimeUpdates`, and the `// old name:` marker goes.
  - `Whisky/AppDelegate.swift`: call the migrations in `applicationWillFinishLaunching`.

**Interfaces:**
- Consumes `GPTKImporter.storeFolder`, `GPTKImporter.adoptModuleFolder(inPayload:)`, the store verification stamp in `GPTKImporter+StoreVerification.swift`, and `GPTKOriginalsRecord`.
- Produces `public enum AppMigrations`, with:
  - `static let renamedDefaultsKeys: [(old: String, new: String)] = [("checkWhiskyWineUpdates", "checkAnoRuntimeUpdates"), ("wineSectionExpanded", "anoSectionExpanded")]`
  - `static let obsoleteDefaultsKeys = ["hasOfferedLegacyMigration"]`
  - `@discardableResult static func migrateDefaults(_ defaults: UserDefaults, domain: String) -> [String]` (the keys it changed)
  - `@discardableResult static func migrateGPTKStore(at store: URL) -> Bool` (whether it changed anything)
  - `static func runAtLaunch()`

- [ ] **Step 1: Write the failing tests.**
  - `testTheUpdateCheckOptOutIsCarriedOver`: `checkWhiskyWineUpdates = false` is in a suite, and `migrateDefaults` runs. Then `bool(forKey: "checkAnoRuntimeUpdates") == false`, `object(forKey: "checkWhiskyWineUpdates") == nil`, and `WhiskyWineInstaller.automaticUpdateCheckDefaultsKey == "checkAnoRuntimeUpdates"`.
  - `testANewChoiceIsNotOverwritten`: both keys exist, `old = false` and `new = true`. After the migration, `new` is still true and `old` is gone.
  - `testNoOldKeyLeavesTheDefault`: an empty suite; the migration changes nothing (`[]`).
  - `testEveryOtherWineKeyIsDropped`: the domain holds `wineDebugThing = 1`, `WINEsomething = "x"`, `hasOfferedLegacyMigration = true` and `librarySort = "name"`. After the migration only `librarySort` remains.
  - `testAnAno8StoreIsRenamedAndStaysVerified`:
    - Build a store as `GPTKImporter` makes one, but with Ano 8's folder name `lib/wine/x86_64-windows/dxgi.dll`, `lib/external/libd3dshared.dylib` and the record, stamped verified with the existing stamp function.
    - After `migrateGPTKStore`: `lib/ano/x86_64-windows/dxgi.dll` exists, `lib/wine` does not, the store still counts as verified, and `GPTKImporter.storeWindowsFolder(inStoreLib:)` holds `dxgi.dll`.
  - `testAnUnverifiedStoreStaysUnverified`: the same store without the stamp stays without it after the rename.
  - `testOriginalsFromAnEarlierRuntimeAreDropped`: `originals/OriginalsVersion.plist` says runtime `4.9.0`, so `originals/` is removed. With `5.0.0` it stays.
  - `testBothFoldersKeepTheAnoOne`: `lib/ano` and `lib/wine` both exist, so `lib/wine` is removed and `lib/ano` is unchanged.

  Push and dispatch CI. Expected: they fail.
- [ ] **Step 2: Implement.**
  - `migrateDefaults` reads `defaults.persistentDomain(forName: domain)`. For each renamed pair it copies the old value only when the new key is absent, then removes the old key. It removes the obsolete keys and every remaining key that contains "wine" (case-insensitive).
  - `migrateGPTKStore` notes whether the store was verified, renames the folder by `adoptModuleFolder`'s rule (`lib/ano` wins), drops `originals/` when its record names a runtime whose major version is below 5, and stamps the store again only if it was verified before.
  - `runAtLaunch` runs both, against `UserDefaults.standard` with `Bundle.main.bundleIdentifier`, and against `GPTKImporter.storeFolder`.
  - `AppDelegate.applicationWillFinishLaunching` calls `AppMigrations.runAtLaunch()` before anything reads settings, so it comes before the update check and before `WhiskyApp`'s GPTK `ensure…` calls. Check by reading the call sites, and say in the report where each runs.
- [ ] **Step 3:** Commit and dispatch. Expected: CI is green, and Hygiene's checks print 0.

### Task 3: No import from the original Whisky

Every bottle the original Whisky made is an old bottle (decision 3): the import would list bottles that the app then refuses.

**Files:**
- Delete:
  - `Whisky/Views/MigrateBottlesSheet.swift`;
  - `WhiskyKit/Sources/WhiskyKit/Whisky/LegacyBottleImport.swift` and its tests;
  - the catalog keys that only they use (the "original Ano" / "archived original Ano app" texts).
- Modify `Whisky/Views/WhiskyApp.swift`: remove the first-launch offer, the `showMigrate` sheet and the File-menu command. Remove the Xcode project references.

- [ ] **Step 1:** Write a UI test in `WhiskyUITests`, `testTheFileMenuHasNoWhiskyImport`: open the File menu, and assert that no menu item whose title contains "Import" names the original app. Use the current English title of the command, read from the catalog. Push and dispatch CI. Expected: it fails.
- [ ] **Step 2:** Remove the feature.
  - `python scripts/anowine/check_catalog_keys.py` stays at 0, the removed keys are gone from the catalog, and the catalog stays LF and en-GB complete.
  - Grep for the removed type, view and keys: no hits outside the deleted files.
  - Expected: CI is green.
- [ ] **Step 3:** Commit.

### Task 4: Words the reviews found misleading

**Files:**
- `Whisky/Localizable.xcstrings`;
- `Whisky/Views/Bottle/RunningProcessesView.swift` and the settings views that use the kill-on-quit strings;
- `scripts/anowine/check_catalog_keys.py` and its test;
- `WhiskyKit/Sources/WhiskyKit/GameDatabase/Resources/GameDB.json`, `Diagnostics/Resources/remediations.json`, `Troubleshooting/Resources/flows/launcher-issues.json`;
- `WhiskyCmd/Main.swift`;
- the diagnostics writers (`DiagnosticExporter.swift`, `StabilityDiagnostics.swift`, `LauncherDiagnostics.swift`, `FileHandle+Extensions.swift`);
- `WhiskyKit/Sources/WhiskyKit/Audio/WineAudioTestProbe.swift`.

**The changes:**
- `process.detail.anoPID` → key `process.detail.windowsPID`, en "Windows PID".
- `config.cleanup.killOnQuit.help` and `settings.toggle.kill.on.terminate` say "Windows programs", not "Ano processes": "Terminate Windows programs when Ano closes". This applies in every language, using each language's existing word for Windows programs where the catalog has one.
- GameDB anti-cheat workarounds and "until" lines no longer present a vendor's Proton support as what would make the game run in Ano. Proton support is Linux-only, so they say what the vendor would have to support: macOS, or Wine-based layers on macOS. Lines about 485, 1413, 1999, 3344 and 3350, and every other `workaround` that mentions Proton.
- "Whisky" text the reviews named:
  - `ano run` help ("a launch from Whisky", "whisky run MyBottle …") and "is not a Whisky bottle" → Ano / `ano run`;
  - "Whisky Version:" in diagnostics → "Ano version:";
  - the audio probe's log subsystem `com.franke.Whisky` → `Bundle.whiskyBundleIdentifier`;
  - GameDB "Untested on Whisky's runtime", "Whisky picks the backend", remediations "lets Whisky pick", and the Whisky text in `launcher-issues.json` → reworded so they stay true.

- [ ] **Step 1: Write the failing tests.**
  - `test_check_catalog_keys.py`: a key passed as `label: "x.y"` to a `LocalizedStringResource` parameter is checked, as `detailRow(label: "process.detail.missing")` must be reported.
  - `BundledDataNamesTests`: no GameDB `workaround` mentions "Proton", and no GameDB or remediation text except `author` says "Whisky".
  - The tests that assert the CLI help, the diagnostics header and the kill-on-quit text change to the new text.

  Push and dispatch CI and Hygiene. Expected: they fail.
- [ ] **Step 2:** Make the changes. Rename the key with `rename_app_text.py`'s key machinery, or by hand in the catalog and Swift together. Keep the catalog LF, with en-GB. Expected: CI is green, Hygiene is green, and the text, runtime-name and catalog-key checks print 0.
- [ ] **Step 3:** Commit. List every reworded GameDB line in the report.

### Task 5: The owner's script for Rosetta's cache

**Files:** Create `scripts/anowine/clean-rosetta-cache.sh` (mode 100755, LF) and `scripts/anowine/test-clean-rosetta-cache.sh`. Modify `.github/workflows/AnoWineHygiene.yml` (a step) and `docs/anowine/TESTING-ON-M2.md` (a section "Ano 9: clean old traces").

**Interface:** `clean-rosetta-cache.sh [--delete] [--root DIR]`.
- It lists every regular file under `DIR/var/db/oah` (default `DIR` = `/`) whose name matches `*wine*.aot`, case-insensitive, one per line, and prints the count.
- With `--delete` it removes them.
- It refuses `--delete` without root rights unless `--root` is given (exit 2, message "run with sudo").
- It exits 0 with "nothing to clean" when there are none.
- It never follows symlinks (`find -P`).
- Rosetta makes the files again for any program that still needs them.

- [ ] **Step 1:** Write `test-clean-rosetta-cache.sh`. It builds a fake tree:
  - `var/db/oah/u1/h1/winemac.so.aot`, `.../WINEBUS.SO.aot`, `.../anowine.aot`;
  - `.../ano-core.aot` and `.../notes.txt`, which are kept;
  - a symlink `.../link-wine.aot` pointing outside the tree.

  It asserts that:
  - a run without `--delete` lists exactly 3 and deletes nothing;
  - `--delete --root` removes the 3 and keeps the rest;
  - the symlink's target survives;
  - `--delete` without `--root` as non-root exits 2.

  Add the Hygiene step and push. Expected: it fails (no script).
- [ ] **Step 2:** Write the script. Expected: the Hygiene step passes.
- [ ] **Step 3:** The TESTING section explains:
  - what the script removes and why it needs `sudo`;
  - how to get it (attached to the next `ano-test-N` release; 3c-5 attaches it);
  - the command: `sudo bash ~/Downloads/clean-rosetta-cache.sh` to look first, then the same with `--delete`.
- [ ] **Step 4:** Commit.

### Task 6: Report

- [ ] `spikes/REPORT.md` "## Plan 3c-4c: first launch": the cleanup list and what is kept, the migrations and their order, the import removal, the wording fixes, and the admin script. Update the workspace `CLAUDE.md`. Commit.
