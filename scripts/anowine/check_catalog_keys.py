#!/usr/bin/env python3
"""Every localization key the app's Swift names is in its string catalog (Plan 3c-4b).

Usage: check_catalog_keys.py [--root REPO]

A key renamed in Whisky/Localizable.xcstrings but not in Swift (or the
reverse) makes the app show the raw key. This finds, in the Swift of Whisky/
and WhiskyKit/Sources/ (WhiskyKit's lookups run in the app, against its
catalog):

  call        the literal passed to String(localized:), NSLocalizedString,
              LocalizedStringKey or LocalizedStringResource, or as the first
              argument of a SwiftUI view or modifier that takes a
              LocalizedStringKey (Text, Button, Label, Toggle, .help, ...);
  identifier  any other literal that reads as a dotted key (`winetricks.title`)
              in a key namespace: one the catalog's keys or the calls above use
              (so an SF Symbol name or a bundle id is not one);
  prefix      a dotted head joined to code (`"winetricks.category.\\(name)"`),
              a key built at run time: some key must start with the head.

An interpolation \\( ... ) stands for the specifier the catalog has in its
place (%@, %lld, %1$@). Each must name a catalog key. Exit 1 if one does not.
"""
import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from swift_literals import INTERP, key_of, line_of, literals, normalize_key  # noqa: E402

CATALOG = "Whisky/Localizable.xcstrings"
SWIFT_ROOTS = ("Whisky", "WhiskyKit/Sources")
SKIP_PARTS = {"Tests", "WhiskyKitTests", "WhiskyUITests", ".build"}

_VIEWS = ("Text|Button|Label|Toggle|Picker|TextField|SecureField|Section|Link|Menu|GroupBox|DisclosureGroup"
          "|LabeledContent|Stepper|ContentUnavailableView|NavigationLink|TableColumn")
_MODIFIERS = "help|navigationTitle|accessibilityLabel|accessibilityHint|alert|confirmationDialog|badge"
# The code just before a literal that makes it a localization key.
CALL = re.compile(r"(?:\bString\(\s*localized:|\bNSLocalizedString\(|\bLocalizedStringKey\("
                  r"|\bLocalizedStringResource\(|\bString\.LocalizationValue\("
                  rf"|(?<![\w.])(?:{_VIEWS})\(|\.(?:{_MODIFIERS})\(|\.searchable\([^()]*prompt:)\s*$")
LETTER = re.compile(r"[^\W\d_]")
# A dotted identifier, as the catalog's own keys are: `audio.history.count`.
DOTTED = re.compile(r"[a-z][A-Za-z0-9]*(?:\.[A-Za-z0-9_-]+)+")
# Literals that look like keys but name something else.
NOT_A_KEY_BEFORE = re.compile(r"(?:accessibilityIdentifier|identifier:|forKey:|forKeyPath:|subsystem:"
                              r"|category:|Notification\.Name|withIdentifier:|named:|systemName:|systemImage:"
                              r"|bundleIdentifier|label:)\s*\(?\s*$")
# A dotted literal ending in a file extension is a file name (`steam.exe`).
FILE_EXTENSIONS = {"exe", "log", "json", "dll", "plist", "txt", "msi", "bat", "lnk", "sh", "app", "zip",
                   "tar", "gz", "xz", "reg", "ini", "cfg", "dmg", "pdf", "png", "icns", "inf", "sys", "drv"}
# A reverse-DNS name built at run time is not a key (`com.example.\(name)`).
REVERSE_DNS = ("com.", "io.", "org.", "net.")
# Text a view shows as it is, on purpose: a #Preview's filler, a unit after a number.
NOT_LOCALIZED = {"Content", INTERP + " Hz"}


@dataclass
class Miss:
    path: str
    line: int
    rule: str
    key: str


def catalog_keys(root: Path):
    strings = json.loads((root / CATALOG).read_text(encoding="utf-8"))["strings"]
    return set(strings)


def _readable(key: str) -> str:
    return key.replace(INTERP, "\\(...)")


def _namespace(key: str):
    stem = key.split(" ", 1)[0].split(INTERP, 1)[0].rstrip(".")
    return stem.split(".", 1)[0] if DOTTED.fullmatch(stem) else None


def _sites(text: str):
    """(literal's key with INTERPs, line, is it a call, the code before it)."""
    for lit in literals(text):
        before = text[max(0, lit.start - 80):lit.start]
        yield normalize_key(key_of(lit)), line_of(text, lit.start), bool(CALL.search(before)), before


def check_text(rel: str, text: str, keys, normalized, namespaces):
    """Misses in one Swift file."""
    for key, line, call, before in _sites(text):
        if call:
            # Only text with letters is looked up: "•", "1920", "\(a) / \(b)" show as they are.
            if key not in normalized and LETTER.search(key) and key not in NOT_LOCALIZED:
                yield Miss(rel, line, "call", _readable(key))
            continue
        if NOT_A_KEY_BEFORE.search(before):
            continue
        head = key.split(INTERP, 1)[0]
        if INTERP in key and head.endswith(".") and DOTTED.fullmatch(head[:-1]) \
                and not head.startswith(REVERSE_DNS):
            if not any(k.startswith(head) for k in keys):
                yield Miss(rel, line, "prefix", _readable(key))
            continue
        stem = key.split(" ", 1)[0]
        if DOTTED.fullmatch(stem) and "_" not in stem and stem.rsplit(".", 1)[1] not in FILE_EXTENSIONS \
                and stem.split(".", 1)[0] in namespaces and key not in normalized:
            yield Miss(rel, line, "identifier", _readable(key))


def scan(root: Path):
    root = Path(root)
    keys = catalog_keys(root)
    normalized = {normalize_key(k) for k in keys}
    files = []
    for top in SWIFT_ROOTS:
        base = root / top
        for path in sorted(base.rglob("*.swift")) if base.is_dir() else []:
            if not SKIP_PARTS.intersection(path.relative_to(root).parts):
                files.append((path.relative_to(root).as_posix(), path.read_text(encoding="utf-8")))
    # Key namespaces: the catalog's, and those the calls use (a half rename can empty one in the catalog).
    namespaces = {_namespace(k) for k in keys}
    for _, text in files:
        namespaces.update(_namespace(key) for key, _, call, _ in _sites(text) if call)
    namespaces.discard(None)
    for rel, text in files:
        yield from check_text(rel, text, keys, normalized, namespaces)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Every localization key the app's Swift names is in the catalog.")
    parser.add_argument("--root", type=Path, default=HERE.parent.parent)
    args = parser.parse_args(argv)
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    misses = list(scan(args.root))
    for miss in misses:
        print(f"{miss.path}:{miss.line}: {miss.rule}: {miss.key[:120]}")
    print(f"localization keys missing from {CATALOG}: {len(misses)}")
    return 1 if misses else 0


if __name__ == "__main__":
    sys.exit(main())
