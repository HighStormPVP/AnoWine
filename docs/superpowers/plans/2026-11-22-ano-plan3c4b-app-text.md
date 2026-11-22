# Ano Plan 3c-4b — what users see

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Nothing the app shows, logs or carries in its bundle says "wine" (any case): UI text in every language, localization keys, log categories and messages, CLI text, `Info.plist`, the bottle symbol, troubleshooting flows, remediations, GameDB keys and text, `verbs.txt`. Code-only names (Swift identifiers, file and type names) stay (decision 6).

**Architecture:** A full source check (`check_app_text.py`, Hygiene) extends 3c-4a's lint to every Swift literal (interpolations excluded: they are code), every bundled resource (JSON, `Localizable.xcstrings` keys and values, `Info.plist`, `Libraries/verbs.txt`) and fails on any "wine"; it starts red and ends green. Localization keys and values are renamed by a script (`rename_app_text.py`) that applies the rule with a reviewed list of rewordings for text about the real Wine project; Swift text, JSON and the symbol are changed by hand, task by task, tests first where behaviour is involved (GameDB and flow decoding).

**Tech Stack:** Swift, Python 3, GitHub Actions (`CI`, `AnoWine Hygiene`).

**Spec:** `docs/superpowers/specs/2026-11-18-ano-full-rename-design.md`: G1 (UI and localizations, plist and defaults keys, log categories and text, exports), decision 6 (code-only names stay), How 6 (UI strings in all localizations, log categories, GameDB.json, troubleshooting flows, the `wineglass` symbol (replaced, my call), the permission prompt). Inventory: `.superpowers/sdd/2026-11-21-ano-plan3c4a-app-runtime/app-inventory.md` (categories C, D, E, F).

## Global Constraints

- **Rule for text:** `Wine` → `Ano`, `wine` → `ano`, `WINE` → `ANO`; a program name gets `ano-` (`winetricks` → `ano-tricks`, `Winetricks` → `Ano-tricks`, `winecfg` → `ano-cfg`, `wineserver` → `ano-server`); `WhiskyWine` (the runtime, in text) → `Ano runtime`; `WineD3D` → `AnoD3D` (the engine's `anod3d`). Text about the real Wine project or other products ("Wine/Proton support", "WineHQ bug 56463", "under Wine") is reworded so it stays true without the word (for example "Proton (Linux)", "the engine's", "upstream bug 56463"); each rewording is listed in the script's table and in the report.
- **Keys:** a localization key with "wine" is renamed by the same rule in `Localizable.xcstrings` and in every Swift use, together (`rename_app_text.py --keys`). `Localizable.xcstrings` stays LF and keeps an en-GB value for every string (`scripts/british-english.py`).
- **Kept:** Swift identifiers, type and file names (code-only, decision 6), `// old name:` lines (3c-4a), test sources, `Documentation.docc` (not shipped; checked in 3c-4a), the AutoHotkey `IfWinExist` / API set `winevent` in `verbs.txt` (allowlisted not-wine).
- **GameDB keys** (`winetricksVerbs`, `wineVersion`, `minWineVersion`) follow the rule (`anoTricksVerbs`, `anoVersion`, `minAnoVersion`) with their Swift decoding; variant ids with `wine`/`wined3d` follow it too. GameDB is bundled only (no user data).
- **Symbol:** `wineglass` → `flask` (my call: a container, not a drink; available since macOS 13).
- **Info.plist:** the permission text loses "Wine"; the Sparkle feed URL on `highstormpvp.github.io` is removed (Sparkle is off: no `SUPublicEDKey`; `github.io` is blocked on the owner's network).
- **Log categories** (`WineKit`, `Wine`, `WhiskyWineInstaller`, `Winetricks`, …) → `AnoKit`, `Ano`, `AnoRuntimeInstaller`, `AnoTricks`, …
- SwiftLint (120 columns, GPL header, length limits), SwiftFormat. `gh -R HighStormPVP/AnoWine`; RED pushed and watched before GREEN; `[skip ci]` plus dispatch; stage files by path. 3c-4b ships nothing.

## Review Focus

1. A localization key renamed in the catalog but not in Swift (or the reverse): the UI shows the raw key. The check (Task 1) cannot see it; CI's "Fill Missing Translations" assertion and a key-consistency test (Task 2) must.
2. A reworded sentence that changes meaning (anti-cheat notes in GameDB, troubleshooting advice).
3. GameDB or flow JSON keys renamed without their Codable change: entries silently drop.
4. Interpolated code inside a literal (`"\(bottle.settings.wineVersion)"`) mistaken for text, or text hidden inside an interpolation missed.
5. A translation whose grammar depended on "Wine" (gender, case): mechanical replacement in 24 languages.

---

### Task 1: The full source check

**Files:** Create `scripts/anowine/check_app_text.py`, `scripts/anowine/test_check_app_text.py`. Modify `.github/workflows/AnoWineHygiene.yml`.

**Interfaces:** Produces `check_app_text.py [--root REPO]`: reports `file:line: <text>` for every "wine" (any case) in Swift string literals of `Whisky/`, `WhiskyKit/Sources/`, `WhiskyCmd/`, `WhiskyThumbnail/` (interpolations `\( … )` removed first; `// old name:` lines skipped), in every JSON under `WhiskyKit/Sources/WhiskyKit/**/Resources/`, in `Localizable.xcstrings` (keys and every value), `Whisky/Info.plist`, `WhiskyCmd/Info.plist` if present, and `Libraries/verbs.txt` (minus `IfWinExist`/`ifwinexist`/`winevent`). Exit 1 if any; prints a count per file.

- [ ] **Step 1:** tests (a literal, an interpolation not reported, a comment and an identifier not reported, an xcstrings key and value, a JSON value, a plist string, the `// old name:` marker, verbs.txt's AutoHotkey word allowed); the Hygiene step. Push, dispatch Hygiene. Expected: tests pass, the check fails with the inventory's count.
- [ ] **Step 2: Commit.**

### Task 2: Localization keys and values

**Files:** Create `scripts/anowine/rename_app_text.py` (+ tests): `--keys` renames catalog keys and their Swift uses; `--values` applies the rule to every value in every language, with the rewording table. Modify `Whisky/Localizable.xcstrings` and the Swift files that use the renamed keys; add a WhiskyKit or app test that every `String(localized:)` key literal in the sources exists in the catalog (a Python check in Hygiene is acceptable: the app target has no unit tests).

- [ ] **Step 1:** the key-consistency check (RED only if a key is missing: write it, confirm it passes today, then rename keys and confirm it would catch a half rename with a mutation run, ledgered). The script's tests. Push, dispatch Hygiene and CI.
- [ ] **Step 2:** run the script; read every rewording; en-GB; LF. Dispatch CI (Localization job, the bundled-translations check) and Hygiene. Expected: the check lists no xcstrings hits.
- [ ] **Step 3: Commit.**

### Task 3: Swift text, logs, CLI, Info.plist, the symbol

**Files:** the Swift files the check lists (UI literals, log messages and categories, `WhiskyCmd/Main.swift` help text, `Logger+Extensions.swift` categories), `Whisky/Info.plist`, the `wineglass` uses.

- [ ] **Step 1:** where a test asserts text or a category (tests that match log output, CLI help tests, UI tests by label), change the test to the new text first; push, dispatch CI. Expected: those fail.
- [ ] **Step 2:** the code. Expected: CI green; the check lists no Swift or plist hits.
- [ ] **Step 3: Commit.**

### Task 4: GameDB, flows, remediations, verbs.txt

**Files:** `WhiskyKit/Sources/WhiskyKit/GameDatabase/Resources/GameDB.json` and its Codable types, `Troubleshooting/Resources/**`, `Diagnostics/Resources/remediations.json` (key `winetricksVerb` → `anoTricksVerb`) and its Codable type, their tests.

- [ ] **Step 1:** tests: GameDB decodes every entry with the new keys and the count of entries is unchanged; a flow and a remediation decode with the new keys; RED in CI.
- [ ] **Step 2:** JSON and Codable; reworded GameDB notes reviewed one by one. Expected: CI and Hygiene green, the check prints 0.
- [ ] **Step 3: Commit.**

### Task 5: Report

- [ ] `spikes/REPORT.md` "## Plan 3c-4b": what changed, the rewording table, what remains code-only, the check. Workspace `CLAUDE.md`. Commit.
