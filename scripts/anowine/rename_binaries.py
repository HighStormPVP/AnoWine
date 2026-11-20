#!/usr/bin/env python3
"""Rename the binary files of a renamed Wine tree that ship (Plans 3c-1, 3c-2).

Usage: rename_binaries.py --protect FILE --map FILE [--font FILE]... [--padded FILE]... [--pe FILE]...

rename_sources.py leaves binary files alone and lists them. This renames, by
the same rules, the ones that end up in the engine:
  --font    a TrueType font: its name records, its OS/2 vendor code (four
            characters, padded with spaces) and the strings of FontForge's
            'BDF ' table. Needs fontTools (pinned in build-engine.sh).
  --padded  a file of NUL-terminated strings (pidgen's bink.bin): each string
            is renamed in place and padded with NULs to its old length.
  --pe      a PE file we cannot rebuild (wine-mono): every length stays. A
            path component keeps its length by repeating the separator after
            it (wine-mono/ -> ano-mono//); a NUL-terminated ASCII or UTF-16
            string is renamed and padded with NULs; any other change is an
            error. A renamed export table is sorted again, because Wine finds
            exports by binary search.
Exit 1 when a string would grow, or would change where its length is fixed.
"""
import argparse
import re
import struct
import sys
from pathlib import Path

from rename_sources import CASE_RE, load_rules, rename_text, rename_tree

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


ASCII_RUN = re.compile(rb"[\t\n\r\x20-\x7e]+")
UTF16_RUN = re.compile(rb"(?:[\t\n\r\x20-\x7e]\x00)+")
# A path component that says wine, and the separator after it.
PATH_PART = re.compile(r"(?<=[/\\])([^/\\\s]*?(?:wine|Wine|WINE)[^/\\\s]*)([/\\])")


def _rename_run(run: str, terminated: bool, rules, offset: int) -> str:
    def part(match):
        old, sep = match.group(1), match.group(2)
        new = rename_text(old, rules)
        if len(new) > len(old):
            raise ValueError(f"offset {offset:#x}: path part {old!r} would become {new!r}, which does not fit")
        return new + sep * (1 + len(old) - len(new))
    out = PATH_PART.sub(part, run)
    new = rename_text(out, rules)
    if terminated:
        if len(new) > len(run):
            raise ValueError(f"offset {offset:#x}: {run!r} would become {new!r}, which does not fit")
        return new
    if new != out:
        raise ValueError(f"offset {offset:#x}: {run!r} has a fixed length (no NUL after it) and would change")
    return out


def _sort_exports(buf: bytearray) -> None:
    """Sort a PE's export name table (and its ordinals) by name, in place."""
    try:
        if buf[:2] != b"MZ":
            return
        pe = struct.unpack_from("<I", buf, 0x3C)[0]
        if buf[pe:pe + 4] != b"PE\x00\x00":
            return
        sections_count = struct.unpack_from("<H", buf, pe + 6)[0]
        opt_size = struct.unpack_from("<H", buf, pe + 20)[0]
        opt = pe + 24
        dirs = opt + (96 if struct.unpack_from("<H", buf, opt)[0] == 0x10B else 112)
        if struct.unpack_from("<I", buf, dirs - 4)[0] == 0:
            return
        export_rva = struct.unpack_from("<I", buf, dirs)[0]
        sections = [struct.unpack_from("<IIII", buf, opt + opt_size + 40 * i + 8) for i in range(sections_count)]
    except struct.error:
        return
    if not export_rva:
        return

    def at(rva):
        for size, va, raw_size, raw in sections:
            if va <= rva < va + max(size, raw_size):
                return rva - va + raw
        raise ValueError(f"export table RVA {rva:#x} is in no section")
    count, _, names, ordinals = struct.unpack_from("<IIII", buf, at(export_rva) + 24)
    entries = []
    for i in range(count):
        rva = struct.unpack_from("<I", buf, at(names) + 4 * i)[0]
        start = at(rva)
        entries.append((bytes(buf[start:buf.index(b"\x00", start)]), rva,
                        struct.unpack_from("<H", buf, at(ordinals) + 2 * i)[0]))
    entries.sort(key=lambda entry: entry[0])
    for i, (_, rva, ordinal) in enumerate(entries):
        struct.pack_into("<I", buf, at(names) + 4 * i, rva)
        struct.pack_into("<H", buf, at(ordinals) + 2 * i, ordinal)


def rename_pe(data: bytes, rules) -> bytes:
    """Rename a PE file without changing any length (see --pe above)."""
    out = bytearray(data)
    for run_re, encoding, nul in ((ASCII_RUN, "ascii", b"\x00"), (UTF16_RUN, "utf-16-le", b"\x00\x00")):
        snapshot = bytes(out)
        for match in run_re.finditer(snapshot):
            old = match.group(0)
            run = old.decode(encoding)
            if not CASE_RE.search(run):
                continue
            terminated = snapshot[match.end():match.end() + len(nul)] == nul
            new = _rename_run(run, terminated, rules, match.start()).encode(encoding)
            out[match.start():match.end()] = new + b"\x00" * (len(old) - len(new))
    if out != data:
        _sort_exports(out)
    return bytes(out)


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
    parser.add_argument("--pe", type=Path, action="append", default=[])
    parser.add_argument("--tree", type=Path, help="a tree we cannot rebuild: rename_sources.py's pass, then --pe "
                        "on every PE file it lists; each protected entry must be used by one of the two")
    args = parser.parse_args(argv)
    rules = load_rules(args.protect, args.mapping)
    report = None
    if args.tree:
        report = rename_tree(args.tree, rules)
        print(f"renamed paths: {report.renamed_paths}\nchanged files: {report.changed_files}")
        for rel in report.binary_with_wine:
            path = args.tree / rel
            if path.read_bytes()[:2] == b"MZ":
                args.pe.append(path)
            else:
                print(f"binary, not PE\t{rel}")
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
        for path in args.pe:
            data = path.read_bytes()
            try:
                new = rename_pe(data, rules)
            except ValueError as error:
                raise ValueError(f"{path}: {error}") from None
            if new != data:
                path.write_bytes(new)
                print(f"{path}: renamed in place")
    except ValueError as error:
        print(f"rename_binaries.py: {error}", file=sys.stderr)
        return 1
    if report is None:
        return 0
    problems = [f"conflict\t{c}" for c in report.conflicts]
    problems += [f"unused protected text\t{t}" for t in rules.protect_texts if t not in rules.used]
    for problem in problems:
        print(problem)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
