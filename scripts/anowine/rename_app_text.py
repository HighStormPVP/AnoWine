#!/usr/bin/env python3
"""Rename "wine" in the app's string catalog and the Swift that names its keys (Plan 3c-4b).

Usage: rename_app_text.py [--root REPO] [--keys] [--values] [--dry-run]

--keys    renames every key of Whisky/Localizable.xcstrings that says wine, and
          every Swift literal that names it, in the app (Whisky/, WhiskyKit/Sources/,
          WhiskyCmd/, WhiskyThumbnail/) and its tests (WhiskyKit/Tests/,
          WhiskyUITests/): the key itself, the key with its arguments filled in
          (a test's expected lookup result), and the head of a key built at run time
          ("winetricks.category.\\(name)"). A dotted key takes the code form, as
          the GameDB keys do: whiskywine -> anoRuntime, winetricks -> anoTricks,
          wineserver -> anoServer, winecfg -> anoCfg, then Wine/wine/WINE ->
          Ano/ano/ANO (`setup.whiskywine.download` -> `setup.anoRuntime.download`).
          A key that is English text takes the text rule. A new key that is
          already a key fails the run.
--values  applies the text rule to every value in every language: the REWORDINGS
          first (each printed for review), then WhiskyWine -> "Ano runtime"
          (English) or "Ano", a program name -> ano-<name> (winetricks ->
          ano-tricks, Winetricks -> Ano-tricks, wineserver -> ano-server, ...),
          then Wine/wine/WINE -> Ano/ano/ANO (WineD3D -> AnoD3D, WINEDEBUG ->
          ANODEBUG). A value whose format specifiers change fails the run.
--dry-run prints what would change and writes nothing.

The catalog is written the way Xcode writes it (rebrand_strings.dump), with LF
line endings. Run scripts/british-english.py afterwards. Running it again
changes nothing.
"""
import argparse
import json
import re
import sys
from collections import Counter
from dataclasses import dataclass
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from rebrand_strings import dump  # noqa: E402
from swift_literals import Literal, key_of, line_of, literals, normalize_key, SPECIFIER  # noqa: E402

CATALOG = "Whisky/Localizable.xcstrings"
SWIFT_ROOTS = ("Whisky", "WhiskyKit/Sources", "WhiskyKit/Tests", "WhiskyCmd", "WhiskyThumbnail", "WhiskyUITests")
ENGLISH = ("en", "en-GB")
ANY = None

WINE = re.compile("wine", re.I)
WHISKYWINE = re.compile(r"\bWhiskyWine\b")
PROGRAM = re.compile(r"(?<![A-Za-z])(wine)(tricks?|server|cfg|boot|dbg|device|path|console|menubuilder|file|browser)",
                     re.I)
# A key like `audio.history.count` (arguments may follow a space): not shown, code form.
DOTTED = re.compile(r"[a-z][A-Za-z0-9]*(?:\.[A-Za-z0-9_%@-]+)+")


@dataclass(frozen=True)
class Rewording:
    """Text the plain rule would make untrue or ungrammatical, reworded first."""
    languages: tuple
    pattern: re.Pattern
    replacement: str
    why: str

    def applies(self, lang: str) -> bool:
        return self.languages is ANY or lang in self.languages


def _r(languages, pattern, replacement, why):
    return Rewording(languages, re.compile(pattern), replacement, why)


REWORDINGS = (
    # English: what the text says about the engine and the real Wine project.
    _r(ENGLISH, r"\blike Wine,", "like Ano's engine,",
       "Rosetta runs the x86 engine; the Ano app itself is native"),
    _r(ENGLISH, r"\bAno cannot find Wine's own Direct3D for this engine\b", "Ano cannot find this engine's own Direct3D",
       "Wine's own Direct3D is the engine's built-in d3d11"),
    _r(ENGLISH, r"\bWine's own Direct3D\b", "the engine's own Direct3D",
       "Wine's own Direct3D is the engine's built-in d3d11"),
    _r(ENGLISH, r"\bWine's d3d11\.dll\b", "the engine's d3d11.dll",
       "the engine's built-in d3d11.dll; 'Ano puts Ano's' would read as two things"),
    # Grammar the plain rule would break.
    _r(ENGLISH, r"\b([Aa]) (?=Wine\b)", r"\1n ", "English: an Ano"),
    _r(("fr",), r"\b([DdLl])[ea] (?=[Ww]ine)", r"\1'", "French elision: d'Ano, l'Ano"),
    _r(("fr",), r"\b([Qq]u)e (?=[Ww]ine)", r"\1'", "French elision: qu'Ano"),
    _r(("cs",), r"\b([Vv])e (?=Wine\b)", r"\1 ", "Czech: 've' only before a v/f/w cluster: v Ano"),
    _r(("fi",), r"\bWineä\b", "Anoa", "Finnish vowel harmony: partitive Anoa"),
    _r(("tr",), r"\bWine'(?:ın|nin|in|nın)\b", "Ano'nun", "Turkish vowel harmony: genitive Ano'nun"),
    _r(("tr",), r"\bWine'ı\b", "Ano'yu", "Turkish vowel harmony: accusative Ano'yu"),
    _r(("tr",), r"\bWine'(?:a|e)\b", "Ano'ya", "Turkish vowel harmony: dative Ano'ya"),
    _r(("ko",), r"Wine이(?=\s)", "Ano가", "Korean: subject particle after a vowel (아노)"),
    _r(("ko",), r"Wine과(?=\s)", "Ano와", "Korean: 'with' particle after a vowel"),
    _r(("ko",), r"Wine은(?=\s)", "Ano는", "Korean: topic particle after a vowel"),
    _r(("ko",), r"Wine을(?=\s)", "Ano를", "Korean: object particle after a vowel"),
    _r(("ko",), r"Wine으로", "Ano로", "Korean: instrumental particle after a vowel"),
    _r(("pl",), r"\bWINE(?= \(WINEDEBUG\))", "Ano", "Polish: the name, not an all-caps word"),
)


@dataclass
class Change:
    where: str
    lang: str
    before: str
    after: str
    why: str


def _cased(found: str, word: str) -> str:
    """word in the case of found: WINE -> ANO, Wine (or W) -> Ano, wine -> ano."""
    if len(found) > 1 and found.isupper():
        return word.upper()
    if found[0].isupper():
        return word[0].upper() + word[1:]
    return word


def rename_text(text: str, lang: str, changes=None, where: str = "") -> str:
    """The text rule, with the rewordings for lang first. A value a rewording
    touched is added to changes (before and after the whole rule)."""
    original, why = text, []
    for rewording in REWORDINGS:
        if rewording.applies(lang):
            new = rewording.pattern.sub(rewording.replacement, text)
            if new != text:
                why.append(rewording.why)
                text = new
    text = WHISKYWINE.sub("Ano runtime" if lang in ENGLISH else "Ano", text)
    text = PROGRAM.sub(lambda m: _cased(m.group(1), "ano") + "-" + m.group(2), text)
    text = WINE.sub(lambda m: _cased(m.group(0), "ano"), text)
    if why and changes is not None:
        changes.append(Change(where, lang, original, text, "; ".join(why)))
    return text


def is_dotted(key: str) -> bool:
    return DOTTED.fullmatch(key.split(" ", 1)[0]) is not None


def rename_stem(stem: str) -> str:
    """The code form, for a dotted key's identifier part."""
    stem = re.sub(r"([Ww])hisky[Ww]ine", lambda m: _cased(m.group(1), "anoRuntime"), stem)
    stem = re.sub(r"([Ww])ine(trick|server|cfg)", lambda m: _cased(m.group(1), "ano") + m.group(2).capitalize(), stem)
    return WINE.sub(lambda m: _cased(m.group(0), "ano"), stem)


def rename_key(key: str) -> str:
    if is_dotted(key):
        stem, space, rest = key.partition(" ")
        return rename_stem(stem) + space + rest
    return rename_text(key, "en")


class RenameError(RuntimeError):
    pass


def key_renames(strings) -> dict:
    """Old key -> new key for every key that says wine; fails on a collision."""
    renames = {key: rename_key(key) for key in strings if WINE.search(key)}
    taken = Counter(renames.values())
    for old, new in renames.items():
        if WINE.search(new):
            raise RenameError(f"key {old!r} still says wine as {new!r}")
        if new in strings and new != old:
            raise RenameError(f"key {old!r} -> {new!r}: {new!r} is already a key")
        if taken[new] > 1:
            raise RenameError(f"two keys become {new!r}")
    return renames


def rename_catalog_keys(catalog, renames) -> None:
    catalog["strings"] = {renames.get(key, key): entry for key, entry in catalog["strings"].items()}


def _unit_values(node):
    """Every stringUnit dict in a localization, variations and substitutions included."""
    if isinstance(node, dict):
        unit = node.get("stringUnit")
        if isinstance(unit, dict) and isinstance(unit.get("value"), str):
            yield unit
        for key, child in node.items():
            if key != "stringUnit":
                yield from _unit_values(child)


def rename_catalog_values(catalog, changes) -> int:
    """Applies the text rule to every value. Returns how many values changed."""
    count = 0
    for key, entry in catalog["strings"].items():
        for lang, localization in entry.get("localizations", {}).items():
            for unit in _unit_values(localization):
                old = unit["value"]
                new = rename_text(old, lang, changes, key)
                if new == old:
                    continue
                if sorted(SPECIFIER.findall(old)) != sorted(SPECIFIER.findall(new)):
                    raise RenameError(f"{key} [{lang}]: format specifiers changed: {old!r} -> {new!r}")
                for bad in ("  ", "Ano Ano", "Ano-Ano", "ano ano"):
                    if bad in new and bad not in old:
                        raise RenameError(f"{key} [{lang}]: {bad!r} in {new!r}")
                unit["value"] = new
                count += 1
    return count


# --- Swift -------------------------------------------------------------------

@dataclass
class Edit:
    start: int
    end: int
    new: str


def _replace_head(lit: Literal, text: str, old: str, new: str):
    """An edit swapping the literal's leading old for new, or None."""
    kind, source = lit.parts[0]
    if kind != "text" or not source.startswith(old):
        return None
    start = lit.spans[0][0]
    return Edit(start, start + len(old), new)


def _rename_literal(lit: Literal, text: str, renames, by_norm, by_stem, prefixes):
    """Edits that rename the key this literal names, or [] if it names none."""
    found = normalize_key(key_of(lit))
    old = by_norm.get(found)
    if old is not None:
        new = renames[old]
        if is_dotted(old):
            edit = _replace_head(lit, text, old.split(" ", 1)[0], new.split(" ", 1)[0])
            if edit is None:
                raise RenameError(f"cannot rename key {old!r} in literal at offset {lit.start}")
            return [edit]
        return [Edit(s, e, rename_text(source, "en")) for (kind, source), (s, e) in zip(lit.parts, lit.spans)
                if kind == "text" and rename_text(source, "en") != source]
    first_kind, first = lit.parts[0]
    if first_kind != "text":
        return []
    # A key's identifier followed by its arguments, as a test expects a lookup to read.
    stem = first.split(" ", 1)[0]
    if stem in by_stem and (stem == first or first.startswith(stem + " ")):
        return [_replace_head(lit, text, stem, by_stem[stem])]
    # The head of a key built at run time: "winetricks.category.\(name)".
    if len(lit.parts) > 1 and first in prefixes:
        return [_replace_head(lit, text, first, prefixes[first])]
    return []


def _swift_maps(renames):
    by_norm = {normalize_key(old): old for old in renames}
    by_stem = {old.split(" ", 1)[0]: new.split(" ", 1)[0] for old, new in renames.items() if is_dotted(old)}
    prefixes = {}
    for old, new in by_stem.items():
        parts = old.split(".")
        for n in range(1, len(parts)):
            head = ".".join(parts[:n]) + "."
            if WINE.search(head):
                renamed = rename_stem(head)
                if not new.startswith(renamed):
                    raise RenameError(f"prefix {head!r} renames inconsistently in {old!r}")
                prefixes[head] = renamed
    return by_norm, by_stem, prefixes


def rename_swift(text: str, renames, maps):
    """The file with every key it names renamed, and (line, before, after) for each literal."""
    by_norm, by_stem, prefixes = maps
    edits, report = [], []
    for lit in literals(text):
        found = _rename_literal(lit, text, renames, by_norm, by_stem, prefixes)
        if not found:
            continue
        before = text[lit.start:lit.end]
        after = before
        for edit in sorted(found, key=lambda e: e.start, reverse=True):
            after = after[:edit.start - lit.start] + edit.new + after[edit.end - lit.start:]
        check = next(literals(after))
        old_key, new_key = normalize_key(key_of(lit)), normalize_key(key_of(check))
        if old_key in by_norm and normalize_key(renames[by_norm[old_key]]) != new_key:
            raise RenameError(f"literal at line {line_of(text, lit.start)} became {new_key!r}, "
                              f"not the key {renames[by_norm[old_key]]!r}")
        edits.extend(found)
        report.append((line_of(text, lit.start), before, after))
    for edit in sorted(edits, key=lambda e: e.start, reverse=True):
        text = text[:edit.start] + edit.new + text[edit.end:]
    return text, report


def swift_files(root: Path):
    for top in SWIFT_ROOTS:
        base = root / top
        yield from (sorted(base.rglob("*.swift")) if base.is_dir() else [])


# --- main --------------------------------------------------------------------

def _read(path: Path) -> str:
    return path.read_bytes().decode("utf-8")


def _write(path: Path, text: str) -> None:
    path.write_bytes(text.encode("utf-8"))


def run(root: Path, keys: bool, values: bool, dry_run: bool, out=sys.stdout) -> int:
    root = Path(root)
    path = root / CATALOG
    raw = _read(path)
    catalog = json.loads(raw)
    swift_out = {}
    if keys:
        renames = key_renames(catalog["strings"])
        for old, new in renames.items():
            print(f"key: {old!r} -> {new!r}", file=out)
        rename_catalog_keys(catalog, renames)
        maps = _swift_maps(renames)
        for swift in swift_files(root):
            text = _read(swift)
            new_text, report = rename_swift(text, renames, maps)
            for line, before, after in report:
                print(f"swift: {swift.relative_to(root).as_posix()}:{line}: {before[:90]} -> {after[:90]}",
                      file=out)
            if new_text != text:
                swift_out[swift] = new_text
        print(f"keys renamed: {len(renames)}; Swift files changed: {len(swift_out)}", file=out)
    if values:
        changes = []
        count = rename_catalog_values(catalog, changes)
        for change in changes:
            print(f"reworded: {change.where} [{change.lang}] ({change.why}):\n"
                  f"    {change.before}\n -> {change.after}", file=out)
        print(f"values changed: {count}; reworded by the table: {len(changes)}", file=out)
    new_raw = dump(catalog)
    if dry_run:
        return 0
    if new_raw != raw:
        _write(path, new_raw)
    for swift, text in swift_out.items():
        _write(swift, text)
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description='Rename "wine" in the string catalog and its Swift keys.')
    parser.add_argument("--root", type=Path, default=HERE.parent.parent)
    parser.add_argument("--keys", action="store_true", help="rename keys and their Swift uses")
    parser.add_argument("--values", action="store_true", help="rename values in every language")
    parser.add_argument("--dry-run", action="store_true", help="print the changes, write nothing")
    args = parser.parse_args(argv)
    if not (args.keys or args.values):
        parser.error("say --keys, --values or both")
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    try:
        return run(args.root, args.keys, args.values, args.dry_run)
    except RenameError as error:
        print(f"rename_app_text: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
