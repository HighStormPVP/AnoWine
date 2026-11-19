#!/usr/bin/env python3
"""Rename the binary files of a renamed Wine tree that ship (Plan 3c-1).

Usage: rename_binaries.py --protect FILE --map FILE [--font FILE]... [--padded FILE]...

rename_sources.py leaves binary files alone and lists them. This renames, by
the same rules, the ones that end up in the engine:
  --font    a TrueType font: its name records, its OS/2 vendor code (four
            characters, padded with spaces) and the strings of FontForge's
            'BDF ' table. Needs fontTools (pinned in build-engine.sh).
  --padded  a file of NUL-terminated strings (pidgen's bink.bin): each string
            is renamed in place and padded with NULs to its old length.
Exit 1 when a string would grow and cannot be renamed in place.
"""
import argparse
import re
import sys
from pathlib import Path

from rename_sources import load_rules, rename_text

# A NUL-terminated run of printable ASCII (and line breaks) that says "wine".
STRING = re.compile(rb"[\t\n\r\x20-\x7e]*(?i:wine)[\t\n\r\x20-\x7e]*(?=\x00)")


def rename_padded(data: bytes, rules) -> bytes:
    """Rename every NUL-terminated string in place; ValueError if one grows."""
    def swap(match):
        old = match.group(0)
        new = rename_text(old.decode("ascii"), rules).encode("ascii")
        if len(new) > len(old):
            raise ValueError(f"{old.decode('ascii')!r} would become {new.decode('ascii')!r}, which does not fit")
        return new + b"\x00" * (len(old) - len(new))
    return STRING.sub(swap, data)


def rename_font(path: Path, rules) -> list:
    """Rewrite a TrueType font in place; returns one line per change."""
    from fontTools.ttLib import TTFont

    font = TTFont(path, recalcTimestamp=False)
    changes = []
    for record in font["name"].names:
        old = record.toUnicode()
        new = rename_text(old, rules)
        if new != old:
            record.string = new
            changes.append(f"name {record.nameID} ({record.platformID}): {old!r} -> {new!r}")
    if "OS/2" in font:
        old = font["OS/2"].achVendID
        new = rename_text(old.rstrip(), rules).ljust(4)
        if new.rstrip() != old.rstrip():
            if len(new) != 4:
                raise ValueError(f"{path}: vendor code {old!r} would become {new!r}")
            font["OS/2"].achVendID = new
            changes.append(f"OS/2 vendor: {old!r} -> {new!r}")
    if "BDF " in font:
        old = font["BDF "].data
        new = rename_padded(old, rules)
        if new != old:
            font["BDF "].data = new
            changes.append("BDF strings")
    font.save(path)
    return changes


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Rename the shipped binary files of a renamed Wine tree.")
    parser.add_argument("--protect", type=Path, required=True)
    parser.add_argument("--map", type=Path, required=True, dest="mapping")
    parser.add_argument("--font", type=Path, action="append", default=[])
    parser.add_argument("--padded", type=Path, action="append", default=[])
    args = parser.parse_args(argv)
    rules = load_rules(args.protect, args.mapping)
    try:
        for path in args.font:
            for change in rename_font(path, rules):
                print(f"{path}: {change}")
        for path in args.padded:
            data = path.read_bytes()
            new = rename_padded(data, rules)
            if new != data:
                path.write_bytes(new)
                print(f"{path}: strings renamed in place")
    except ValueError as error:
        print(f"rename_binaries.py: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
