#!/usr/bin/env python3
"""Decide whether two runtime trees are the same build.

Usage: compare_runtimes.py OURS REFERENCE [--report FILE] [--expect-different RELPATH]...
                           [--explained-interface FILE]

OURS and REFERENCE are folders that each hold a `Libraries/` tree (an extracted
Libraries.tar.gz). Every path under `Libraries/` is compared:

  identical          same kind, same bytes, same execute bit, same link target
  timestamps         files that are equal once build-time stamps and values
                     derived from them are zeroed: PE timestamps, checksum and
                     CodeView build ID; Mach-O object modification times
                     (N_OSO), UUID and code signature
  interface          Mach-O or PE files whose bytes differ but whose interface
                     (architectures, minimum macOS, exports, imports,
                     dependencies, signing identifier) is the same
  different          anything else
  only-in-ours / only-in-reference
  expected           a path named with --expect-different that differs, or an
                     interface row listed in the --explained-interface file
                     (path<TAB>reason per line, # comments)

Exit 0: reproduced (only identical, timestamps, expected). Exit 2: equivalent
(some interface rows, nothing worse). Exit 1: different. Exit 3: usage error.
"""
import argparse
import os
import stat
import struct
import subprocess
import sys
from pathlib import Path
from typing import NamedTuple, Optional

CLASSES = ("identical", "timestamps", "interface", "different",
           "only-in-ours", "only-in-reference", "expected")
MACHO_MAGICS = (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf",
                b"\xfe\xed\xfa\xce", b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf")
USAGE_ERROR = 3


class Entry(NamedTuple):
    kind: str  # file, dir, link or other
    executable: bool
    target: Optional[str]


class Result(NamedTuple):
    exit_code: int
    rows: list  # (class, relpath, reason) for every non-identical path
    counts: dict


def walk_tree(root: Path) -> dict:
    """Every path under root/Libraries, keyed by its path relative to root."""
    entries = {}

    def visit(folder: Path, rel: str):
        with os.scandir(folder) as it:
            for item in sorted(it, key=lambda e: e.name):
                relpath = f"{rel}/{item.name}"
                if item.is_symlink():
                    entries[relpath] = Entry("link", False, os.readlink(item.path))
                elif item.is_dir(follow_symlinks=False):
                    entries[relpath] = Entry("dir", False, None)
                    visit(Path(item.path), relpath)
                elif item.is_file(follow_symlinks=False):
                    mode = item.stat(follow_symlinks=False).st_mode
                    entries[relpath] = Entry("file", bool(mode & stat.S_IXUSR), None)
                else:
                    entries[relpath] = Entry("other", False, None)

    visit(Path(root) / "Libraries", "Libraries")
    return entries


class _PE:
    """Just enough of a PE image to find the directories we need."""

    def __init__(self, data: bytes):
        if len(data) < 0x40 or data[:2] != b"MZ":
            raise ValueError("not MZ")
        self.data = data
        self.e = struct.unpack_from("<I", data, 0x3C)[0]
        if self.e + 24 > len(data) or data[self.e:self.e + 4] != b"PE\0\0":
            raise ValueError("no PE signature")
        self.machine, nsections = struct.unpack_from("<HH", data, self.e + 4)
        opt_size = struct.unpack_from("<H", data, self.e + 20)[0]
        self.opt = self.e + 24
        magic = struct.unpack_from("<H", data, self.opt)[0]
        if magic == 0x20B:
            self.pe32plus = True
            self.image_base = struct.unpack_from("<Q", data, self.opt + 24)[0]
            ndirs = struct.unpack_from("<I", data, self.opt + 108)[0]
            dirs = self.opt + 112
        elif magic == 0x10B:
            self.pe32plus = False
            self.image_base = struct.unpack_from("<I", data, self.opt + 28)[0]
            ndirs = struct.unpack_from("<I", data, self.opt + 92)[0]
            dirs = self.opt + 96
        else:
            raise ValueError("unknown optional header magic")
        self.dirs = []
        for i in range(min(ndirs, 16)):
            if dirs + 8 * i + 8 > len(data):
                break
            self.dirs.append(struct.unpack_from("<II", data, dirs + 8 * i))
        self.sections = []
        table = self.opt + opt_size
        for i in range(nsections):
            off = table + 40 * i
            if off + 40 > len(data):
                break
            vsize, va, rawsize, rawptr = struct.unpack_from("<IIII", data, off + 8)
            self.sections.append((va, max(vsize, rawsize), rawptr, rawsize))

    def directory(self, index: int):
        if index < len(self.dirs) and self.dirs[index][0]:
            return self.dirs[index]
        return (0, 0)

    def offset(self, rva: int) -> Optional[int]:
        for va, size, rawptr, rawsize in self.sections:
            if va <= rva < va + size and rva - va < rawsize:
                off = rawptr + rva - va
                return off if off < len(self.data) else None
        return None

    def u16(self, rva):
        off = self.offset(rva)
        return None if off is None or off + 2 > len(self.data) else struct.unpack_from("<H", self.data, off)[0]

    def u32(self, rva):
        off = self.offset(rva)
        return None if off is None or off + 4 > len(self.data) else struct.unpack_from("<I", self.data, off)[0]

    def u64(self, rva):
        off = self.offset(rva)
        return None if off is None or off + 8 > len(self.data) else struct.unpack_from("<Q", self.data, off)[0]

    def cstr(self, rva) -> str:
        off = self.offset(rva)
        if off is None:
            return "?"
        end = self.data.find(b"\0", off, off + 512)
        return self.data[off:end if end >= 0 else off + 512].decode("latin-1")


def pe_normalized(data: bytes) -> Optional[bytes]:
    """The PE file with its build timestamps and checksum zeroed, or None if not a PE."""
    try:
        pe = _PE(data)
    except (ValueError, struct.error):
        return None
    out = bytearray(data)

    def zero(off):
        if off is not None and 0 <= off and off + 4 <= len(out):
            out[off:off + 4] = b"\0\0\0\0"

    zero(pe.e + 8)  # COFF TimeDateStamp
    zero(pe.opt + 64)  # CheckSum
    export_rva, _ = pe.directory(0)
    if export_rva:
        off = pe.offset(export_rva)
        zero(off + 4 if off is not None else None)
    debug_rva, debug_size = pe.directory(6)
    if debug_rva:
        for i in range(debug_size // 28):
            off = pe.offset(debug_rva + 28 * i)
            zero(off + 4 if off is not None else None)
            # ld --build-id: a CodeView record whose GUID is a hash of the link
            # output (export timestamp included), so it changes with the time.
            if off is not None and off + 28 <= len(out) and struct.unpack_from("<I", data, off + 12)[0] == 2:
                raw = struct.unpack_from("<I", data, off + 24)[0]
                if data[raw:raw + 4] == b"RSDS" and raw + 20 <= len(out):
                    out[raw + 4:raw + 20] = bytes(16)
    resource_rva, _ = pe.directory(2)
    if resource_rva:
        seen = set()
        pending = [0]
        while pending:
            rel = pending.pop()
            if rel in seen or len(seen) > 100000:
                continue
            seen.add(rel)
            off = pe.offset(resource_rva + rel)
            if off is None or off + 16 > len(data):
                continue
            zero(off + 4)
            named, ids = struct.unpack_from("<HH", data, off + 12)
            for i in range(named + ids):
                entry = off + 16 + 8 * i
                if entry + 8 > len(data):
                    break
                target = struct.unpack_from("<I", data, entry + 4)[0]
                if target & 0x80000000:
                    pending.append(target & 0x7FFFFFFF)
    return bytes(out)


def _macho_slice_normalize(out: bytearray, base: int) -> None:
    """Zero one thin 64-bit Mach-O's build-time stamps in place: the N_OSO
    entries' object modification times, LC_UUID, and the code signature
    (a hash of the pages, so of the stamps too)."""
    if struct.unpack_from("<I", out, base)[0] != 0xFEEDFACF:
        raise ValueError("not a 64-bit little-endian Mach-O")
    ncmds, sizeofcmds = struct.unpack_from("<II", out, base + 16)
    off, end, symtab = base + 32, base + 32 + sizeofcmds, None
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", out, off)
        if size < 8 or off + size > end:
            raise ValueError("bad load command")
        if cmd == 0x1B:  # LC_UUID
            out[off + 8:off + 24] = bytes(16)
        elif cmd == 0x1D:  # LC_CODE_SIGNATURE
            dataoff, datasize = struct.unpack_from("<II", out, off + 8)
            if base + dataoff + datasize > len(out):
                raise ValueError("bad signature")
            out[base + dataoff:base + dataoff + datasize] = bytes(datasize)
        elif cmd == 0x2:  # LC_SYMTAB
            symtab = struct.unpack_from("<II", out, off + 8)
        off += size
    if symtab:
        symoff, nsyms = symtab
        if base + symoff + 16 * nsyms > len(out):
            raise ValueError("bad symbol table")
        for i in range(nsyms):
            entry = base + symoff + 16 * i
            if out[entry + 4] == 0x66:  # N_OSO: n_value is the object's mtime
                out[entry + 8:entry + 16] = bytes(8)


def macho_normalized(data: bytes) -> Optional[bytes]:
    """The Mach-O file (thin or universal, 64-bit) with its build-time stamps
    zeroed, or None if it cannot be read that way."""
    out = bytearray(data)
    try:
        if data[:4] == b"\xca\xfe\xba\xbe":
            for i in range(struct.unpack_from(">I", data, 4)[0]):
                offset = struct.unpack_from(">I", data, 8 + 20 * i + 8)[0]
                _macho_slice_normalize(out, offset)
        else:
            _macho_slice_normalize(out, 0)
    except (ValueError, struct.error, IndexError):
        return None
    return bytes(out)


def _thunk_names(pe: _PE, dll: str, table_rva: int, rva_based: bool = True) -> list:
    names = []
    width = 8 if pe.pe32plus else 4
    flag = 1 << (63 if pe.pe32plus else 31)
    for i in range(65536):
        value = pe.u64(table_rva + width * i) if pe.pe32plus else pe.u32(table_rva + width * i)
        if not value:
            break
        if value & flag:
            names.append(f"{dll}!#{value & 0xFFFF}")
        else:
            hint_rva = value if rva_based else value - pe.image_base
            names.append(f"{dll}!{pe.cstr((hint_rva + 2) & 0xFFFFFFFF)}")
    return names


def pe_interface(data: bytes) -> dict:
    """Machine, exports, imports, delay imports and the 16 bytes at 0x40."""
    pe = _PE(data)
    exports = []
    export_rva, _ = pe.directory(0)
    if export_rva:
        base = pe.u32(export_rva + 16) or 0
        nfuncs = pe.u32(export_rva + 20) or 0
        nnames = pe.u32(export_rva + 24) or 0
        funcs, names, ordinals = (pe.u32(export_rva + 28), pe.u32(export_rva + 32), pe.u32(export_rva + 36))
        named = set()
        for i in range(min(nnames, 65536)):
            name_rva = pe.u32(names + 4 * i)
            ordinal = pe.u16(ordinals + 2 * i)
            if name_rva is None or ordinal is None:
                break
            exports.append(pe.cstr(name_rva))
            named.add(ordinal)
        for i in range(min(nfuncs, 65536)):
            if i not in named and pe.u32(funcs + 4 * i):
                exports.append(f"#{base + i}")
    imports = []
    import_rva, _ = pe.directory(1)
    if import_rva:
        for d in range(4096):
            desc = import_rva + 20 * d
            lookup, name_rva, first = pe.u32(desc), pe.u32(desc + 12), pe.u32(desc + 16)
            if not name_rva:
                break
            imports += _thunk_names(pe, pe.cstr(name_rva).lower(), lookup or first)
    delay_imports = []
    delay_rva, _ = pe.directory(13)
    if delay_rva:
        for d in range(4096):
            desc = delay_rva + 32 * d
            attributes, name_rva, names_rva = pe.u32(desc), pe.u32(desc + 4), pe.u32(desc + 16)
            if not name_rva:
                break
            rva_based = bool((attributes or 0) & 1)
            if not rva_based:
                name_rva -= pe.image_base
                names_rva -= pe.image_base
            delay_imports += _thunk_names(pe, pe.cstr(name_rva).lower(), names_rva, rva_based)
    return {
        "machine": pe.machine,
        "exports": sorted(exports),
        "imports": sorted(imports),
        "delay_imports": sorted(delay_imports),
        "stub": data[0x40:0x50].hex(),
    }


def _run(*cmd) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, errors="replace")


def _body_lines(text: str) -> list:
    """Tool output without the per-file header lines ("path:" or "path (for architecture x):")."""
    return [line.strip() for line in text.splitlines() if line.strip() and not line.rstrip().endswith(":")]


def macho_interface(path: Path) -> dict:
    """The interface of a Mach-O file, read with macOS's own tools."""
    p = str(path)
    load = _run("otool", "-l", p).stdout.splitlines()
    minos, rpaths = [], []
    for i, line in enumerate(load):
        words = line.split()
        if words[:2] == ["cmd", "LC_BUILD_VERSION"]:
            for nxt in load[i + 1:i + 6]:
                if nxt.split()[:1] == ["minos"]:
                    minos.append(nxt.split()[1])
        elif words[:2] == ["cmd", "LC_RPATH"]:
            for nxt in load[i + 1:i + 4]:
                if nxt.split()[:1] == ["path"]:
                    rpaths.append(nxt.split()[1])
    deps = [line.split(" (compatibility")[0] for line in _body_lines(_run("otool", "-L", p).stdout)]
    identifier = ""
    for line in _run("codesign", "-dv", p).stderr.splitlines():
        if line.startswith("Identifier="):
            identifier = line.split("=", 1)[1]
    return {
        "archs": sorted(_run("lipo", "-archs", p).stdout.split()),
        "minos": minos,
        "install_name": _body_lines(_run("otool", "-D", p).stdout),
        "dependencies": deps,
        "rpaths": rpaths,
        "exports": sorted(set(_body_lines(_run("nm", "-gUj", p).stdout))),
        "imports": sorted(set(_body_lines(_run("nm", "-uj", p).stdout))),
        "identifier": identifier,
    }


def _difference(ours: dict, ref: dict) -> str:
    """The first key whose values differ, with up to 5 differing items."""
    for key in list(ours) + [k for k in ref if k not in ours]:
        a, b = ours.get(key), ref.get(key)
        if a == b:
            continue
        if isinstance(a, list) and isinstance(b, list):
            only_ours = [f"+{x}" for x in a if x not in b]
            only_ref = [f"-{x}" for x in b if x not in a]
            items = (only_ours + only_ref) or ["order differs"]
            return f"{key}: {' '.join(items[:5])}"
        return f"{key}: {a!r} != {b!r}"
    return "interface differs"


def classify(ours: Path, ref: Path, macho_interface=macho_interface) -> tuple:
    """Class and reason for two regular files at the same relative path."""
    a, b = Path(ours).read_bytes(), Path(ref).read_bytes()
    if a == b:
        return ("identical", "")
    if a[:2] == b"MZ" and b[:2] == b"MZ":
        na, nb = pe_normalized(a), pe_normalized(b)
        if na is not None and nb is not None:
            if na == nb:
                return ("timestamps", "PE timestamps or checksum only")
            ia, ib = pe_interface(a), pe_interface(b)
            if ia == ib:
                return ("interface", "PE code differs, same machine, exports and imports")
            return ("different", _difference(ia, ib))
    if a[:4] in MACHO_MAGICS and b[:4] in MACHO_MAGICS:
        na, nb = macho_normalized(a), macho_normalized(b)
        if na is not None and na == nb:
            return ("timestamps", "Mach-O object times, UUID or signature only")
        ia, ib = macho_interface(Path(ours)), macho_interface(Path(ref))
        if ia == ib:
            return ("interface", "Mach-O bytes differ, same interface")
        return ("different", _difference(ia, ib))
    return ("different", f"content differs ({len(a)} vs {len(b)} bytes)")


def compare(ours: Path, ref: Path, expected: set, explained: dict = None) -> Result:
    """explained maps a path to the reason its interface-only difference is known."""
    explained = explained or {}
    ours, ref = Path(ours), Path(ref)
    left, right = walk_tree(ours), walk_tree(ref)
    counts = {name: 0 for name in CLASSES}
    rows = []
    for rel in sorted(set(left) | set(right)):
        a, b = left.get(rel), right.get(rel)
        if b is None:
            cls, reason = "only-in-ours", a.kind
        elif a is None:
            cls, reason = "only-in-reference", b.kind
        elif a.kind != b.kind:
            cls, reason = "different", f"kind: {a.kind} != {b.kind}"
        elif a.kind == "link":
            same = a.target == b.target
            cls, reason = ("identical", "") if same else ("different", f"target: {a.target} != {b.target}")
        elif a.kind == "file":
            if a.executable != b.executable:
                cls, reason = "different", f"executable: {a.executable} != {b.executable}"
            else:
                cls, reason = classify(ours / rel, ref / rel)
        else:
            cls, reason = "identical", ""
        if cls not in ("identical", "only-in-ours", "only-in-reference") and rel in expected:
            cls, reason = "expected", f"expected: {reason}"
        elif cls == "interface" and rel in explained:
            cls, reason = "expected", f"explained interface: {explained[rel]}"
        counts[cls] += 1
        if cls != "identical":
            rows.append((cls, rel, reason))
    if counts["different"] or counts["only-in-ours"] or counts["only-in-reference"]:
        code = 1
    elif counts["interface"]:
        code = 2
    else:
        code = 0
    return Result(code, rows, counts)


class _Parser(argparse.ArgumentParser):
    def error(self, message):
        self.print_usage(sys.stderr)
        print(f"{self.prog}: error: {message}", file=sys.stderr)
        raise SystemExit(USAGE_ERROR)


def main(argv: list) -> int:
    parser = _Parser(prog="compare_runtimes.py", description="Compare two runtime trees.")
    parser.add_argument("ours", type=Path)
    parser.add_argument("reference", type=Path)
    parser.add_argument("--report", type=Path)
    parser.add_argument("--expect-different", action="append", default=[], metavar="RELPATH")
    parser.add_argument("--explained-interface", type=Path, metavar="FILE")
    try:
        args = parser.parse_args(argv)
    except SystemExit as stop:
        return stop.code if isinstance(stop.code, int) else USAGE_ERROR
    for root in (args.ours, args.reference):
        if not (root / "Libraries").is_dir():
            print(f"compare_runtimes.py: {root} has no Libraries folder", file=sys.stderr)
            return USAGE_ERROR
    explained = {}
    if args.explained_interface:
        lines = args.explained_interface.read_text(encoding="utf-8").splitlines()
        for number, line in enumerate(lines, 1):
            if not line.strip() or line.startswith("#"):
                continue
            fields = line.split("\t")
            if len(fields) != 2 or not all(fields):
                print(f"compare_runtimes.py: {args.explained_interface} line {number}: expected path<TAB>reason",
                      file=sys.stderr)
                return USAGE_ERROR
            explained[fields[0]] = fields[1]
    result = compare(args.ours, args.reference, set(args.expect_different), explained)
    summary = "summary: " + " ".join(f"{name}={result.counts[name]}" for name in CLASSES)
    lines = [summary] + ["\t".join(row) for row in result.rows]
    text = "\n".join(lines) + "\n"
    if args.report:
        args.report.write_text(text)
    sys.stdout.write(text)
    return result.exit_code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
