#!/usr/bin/env python3
"""List the runtime names in the app that still say Wine (Plan 3c-4a).

Usage: check_app_runtime_names.py [--root REPO]

A runtime name is one the app passes to or expects from the engine, the
runtime folder, ano-tricks or a bottle. It is looked for in the string
literals of the app's Swift sources (Whisky/, WhiskyKit/Sources/, WhiskyCmd/;
not tests, not comments, not identifiers) and in the string tokens of the
JSON resources WhiskyKit bundles. Rules, first match per literal:

  variable       an environment name: WINE..., ANO_WINE_DIR
  registry       Software\\Wine
  folder         a Wine/wine path component: appending(path: "Wine"),
                 Libraries/Wine, lib/wine, share/wine
  file           winetricks, winetricks.log, WinetricksCache, WhiskyWineVersion,
                 a .wine- suffix (.wine-placeholder)
  program        winecfg, wineboot, winedbg, wineserver, ...
  module         wine*.dll/.drv/.sys/.so/.exe, or a bare wine... module name
  engine output  "wine-" (version), "wine:" (message prefix)
  mark           Wine builtin DLL, Wine placeholder DLL

A Swift line that says `// old name: <reason>` is skipped: the old-bottle
check and the mark Apple's D3DMetal DLLs carry need the old text. Exit 1
when any runtime name is left.
"""
import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path

SWIFT_ROOTS = ("Whisky", "WhiskyKit/Sources", "WhiskyCmd")
RESOURCES = "WhiskyKit/Sources/WhiskyKit"
SKIP_PARTS = {"Tests", "WhiskyKitTests", "WhiskyUITests", ".build"}
OLD_NAME = "// old name:"
# Comments, raw strings, multi-line strings, strings: left to right.
SWIFT_SPAN = re.compile(r'//[^\n]*|/\*.*?\*/|(#+)"""(.*?)"""\1|(#+)"((?:[^"\n]|"(?!#))*)"\3'
                        r'|"""(.*?)"""|"((?:\\.|[^"\\\n])*)"', re.S)
JSON_STRING = re.compile(r'"((?:\\.|[^"\\])*)"')
APPENDING = re.compile(r"(?:appending\(path:|appendingPathComponent\()\s*$")
FOLDER_PATH = re.compile(r"(?:^|/)(?:Libraries/Wine|lib/wine|share/wine)(?:/|$)")
RULES = (
    ("variable", re.compile(r"(?<![A-Za-z0-9])WINE[A-Z0-9_]*(?![a-z])")),
    ("registry", re.compile(r"Software\\+Wine\b")),
    ("file", re.compile(r"^winetricks$|winetricks\.log|WinetricksCache|WhiskyWineVersion|whisky-winetricks"
                        r"|\.wine-")),
    ("program", re.compile(r"\bwine(?:cfg|boot|dbg|console|path|file|browser|menubuilder|server|loader|64)\b",
                           re.I)),
    ("module", re.compile(r"\b(?i:wine)[a-z0-9_]*\.(?i:dll|drv|sys|so|exe)\b|^wine[a-z0-9_]*$")),
    ("engine output", re.compile(r"^wine-$|(?:^|[^A-Za-z])wine:")),
    ("mark", re.compile(r"Wine (?:builtin|placeholder) DLL")),
)


@dataclass
class Hit:
    path: str
    line: int
    rule: str
    text: str


# Names that only look like modules: the wineglass SF Symbol is UI (Plan 3c-4b).
NOT_RUNTIME = frozenset(["wineglass"])


def classify(content: str, before: str = "") -> str:
    if content in NOT_RUNTIME:
        return ""
    if content in ("Wine", "wine") and APPENDING.search(before):
        return "folder"
    if FOLDER_PATH.search(content):
        return "folder"
    for name, pattern in RULES:
        if pattern.search(content):
            return name
    return ""


def _swift(path: Path, rel: str):
    text = path.read_text(encoding="utf-8")
    lines = text.split("\n")
    for match in SWIFT_SPAN.finditer(text):
        if match.group(0).startswith(("//", "/*")):
            continue
        content = next(g for g in (match.group(2), match.group(4), match.group(5), match.group(6)) if g is not None)
        line = text.count("\n", 0, match.start()) + 1
        if OLD_NAME in lines[line - 1]:
            continue
        rule = classify(content, text[max(0, match.start() - 40):match.start()])
        if rule:
            yield Hit(rel, line, rule, content)


def _json(path: Path, rel: str):
    for number, line in enumerate(path.read_text(encoding="utf-8").split("\n"), 1):
        for match in JSON_STRING.finditer(line):
            rule = classify(match.group(1))
            if rule:
                yield Hit(rel, number, rule, match.group(1))


def _skipped(path: Path, root: Path) -> bool:
    return bool(SKIP_PARTS.intersection(path.relative_to(root).parts))


def scan(root: Path):
    root = Path(root)
    for top in SWIFT_ROOTS:
        for path in sorted((root / top).rglob("*.swift")) if (root / top).is_dir() else []:
            if not _skipped(path, root):
                yield from _swift(path, path.relative_to(root).as_posix())
    resources = root / RESOURCES
    for path in sorted(resources.rglob("*.json")) if resources.is_dir() else []:
        if "Resources" in path.relative_to(root).parts and not _skipped(path, root):
            yield from _json(path, path.relative_to(root).as_posix())


def old_name_lines(root: Path) -> int:
    return sum(text.count(OLD_NAME) for top in SWIFT_ROOTS if (Path(root) / top).is_dir()
               for text in (p.read_text(encoding="utf-8") for p in (Path(root) / top).rglob("*.swift")
                            if not _skipped(p, Path(root))))


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="List the app's runtime names that still say Wine.")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent.parent)
    args = parser.parse_args(argv)
    hits = list(scan(args.root))
    for hit in hits:
        print(f"{hit.path}:{hit.line}: {hit.rule}: {hit.text[:100]}")
    print(f"old names kept on purpose (// old name:): {old_name_lines(args.root)}")
    print(f"runtime names that still say Wine: {len(hits)}")
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main())
