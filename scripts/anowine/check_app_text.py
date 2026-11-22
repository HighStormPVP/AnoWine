#!/usr/bin/env python3
"""List every "wine" (any case) the app shows, logs or bundles (Plan 3c-4b).

Usage: check_app_text.py [--root REPO]

Looks at: string literals of the app's Swift sources (Whisky/,
WhiskyKit/Sources/, WhiskyCmd/, WhiskyThumbnail/; not tests, not comments, not
identifiers; interpolations \\( ... ) are code and removed first; a line that
says `// old name: <reason>` is skipped); Whisky/Localizable.xcstrings (every
key and every value in every language); the JSON resources WhiskyKit bundles;
the targets' Info.plist files; Libraries/verbs.txt (where AutoHotkey's
IfWinExist and the API set winevent are not Wine). Code-only names stay
(decision 6). Exit 1 when anything is left.
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

from check_app_runtime_names import OLD_NAME, SKIP_PARTS, SWIFT_SPAN  # noqa: E402

SWIFT_ROOTS = ("Whisky", "WhiskyKit/Sources", "WhiskyCmd", "WhiskyThumbnail")
CATALOG = "Whisky/Localizable.xcstrings"
RESOURCES = "WhiskyKit/Sources/WhiskyKit"
PLISTS = ("Whisky/Info.plist", "WhiskyCmd/Info.plist", "WhiskyThumbnail/Info.plist")
VERBS = "Libraries/verbs.txt"
WINE = re.compile("wine", re.I)
JSON_STRING = re.compile(r'"((?:\\.|[^"\\])*)"')
NOT_WINE_IN_VERBS = re.compile(r"\b(?:IfWinExist|ifwinexist|ifWinExist|winevent)\b")
INTERPOLATION = re.compile(r"\\(#*)\(")


@dataclass
class Hit:
    path: str
    where: str
    text: str


def strip_interpolations(literal: str) -> str:
    """The literal without its \\( ... ) (or \\#( ... ) in a raw string) parts."""
    out, pos = [], 0
    while True:
        match = INTERPOLATION.search(literal, pos)
        if not match:
            out.append(literal[pos:])
            return "".join(out)
        out.append(literal[pos:match.start()])
        depth, i = 1, match.end()
        while i < len(literal) and depth:
            depth += {"(": 1, ")": -1}.get(literal[i], 0)
            i += 1
        pos = i


def _skipped(path: Path, root: Path) -> bool:
    return bool(SKIP_PARTS.intersection(path.relative_to(root).parts))


def _swift(root: Path):
    for top in SWIFT_ROOTS:
        base = root / top
        for path in sorted(base.rglob("*.swift")) if base.is_dir() else []:
            if _skipped(path, root):
                continue
            rel = path.relative_to(root).as_posix()
            text = path.read_text(encoding="utf-8")
            lines = text.split("\n")
            for match in SWIFT_SPAN.finditer(text):
                if match.group(0).startswith(("//", "/*")):
                    continue
                content = next(g for g in (match.group(2), match.group(4), match.group(5), match.group(6))
                               if g is not None)
                line = text.count("\n", 0, match.start()) + 1
                if OLD_NAME in lines[line - 1]:
                    continue
                visible = strip_interpolations(content)
                if WINE.search(visible):
                    yield Hit(rel, str(line), visible)


def _values(node):
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "value" and isinstance(value, str):
                yield value
            else:
                yield from _values(value)
    elif isinstance(node, list):
        for item in node:
            yield from _values(item)


def _catalog(root: Path):
    path = root / CATALOG
    if not path.is_file():
        return
    strings = json.loads(path.read_text(encoding="utf-8")).get("strings", {})
    for key, entry in strings.items():
        if WINE.search(key):
            yield Hit(CATALOG, f"key {key}", key)
        for lang, localization in entry.get("localizations", {}).items():
            bad = [value for value in _values(localization) if WINE.search(value)]
            if bad:
                yield Hit(CATALOG, f"{key} [{lang}]", bad[0])


def _lines(root: Path, rel: str, pick):
    path = root / rel
    if not path.is_file():
        return
    for number, line in enumerate(path.read_text(encoding="utf-8").split("\n"), 1):
        text = pick(line)
        if text is not None and WINE.search(text):
            yield Hit(rel, str(number), text.strip())


def _json_strings(line: str):
    return " ".join(match.group(1) for match in JSON_STRING.finditer(line))


def scan(root: Path):
    root = Path(root)
    yield from _swift(root)
    yield from _catalog(root)
    base = root / RESOURCES
    for path in sorted(base.rglob("*.json")) if base.is_dir() else []:
        if "Resources" in path.relative_to(root).parts and not _skipped(path, root):
            yield from _lines(root, path.relative_to(root).as_posix(), _json_strings)
    for rel in PLISTS:
        yield from _lines(root, rel, lambda line: line)
    yield from _lines(root, VERBS, lambda line: NOT_WINE_IN_VERBS.sub("", line))


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description='List every "wine" the app shows, logs or bundles.')
    parser.add_argument("--root", type=Path, default=HERE.parent.parent)
    args = parser.parse_args(argv)
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    hits = list(scan(args.root))
    for hit in hits:
        print(f"{hit.path}: {hit.where}: {hit.text[:100]}")
    for path, count in Counter(hit.path for hit in hits).most_common():
        print(f"{count:6d} {path}")
    print(f'app text that says "wine": {len(hits)}')
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main())
