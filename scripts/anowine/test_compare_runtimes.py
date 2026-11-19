"""Tests for compare_runtimes.py. Run: python3 -m unittest discover -s scripts/anowine -p 'test_*.py'"""
import io
import os
import struct
import sys
import tempfile
import unittest
from unittest import mock
from contextlib import redirect_stdout
from pathlib import Path

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import compare_runtimes  # noqa: E402
from compare_runtimes import classify, compare, main  # noqa: E402

DOS_STUB = bytes.fromhex("0e1fba0e00b409cd21b8014ccd219090")


def make_pe(timestamp=0, checksum=0, export_ts=0, exports=(), imports=None, code=b"\x90"):
    """A minimal PE32+ DLL (machine 0x8664) with one section at RVA 0x1000.

    `imports` maps a DLL name to a list of names (str) or ordinals (int)."""
    sect_rva, sect_off = 0x1000, 0x200
    sec = bytearray()

    def here():
        return sect_rva + len(sec)

    def put_u32(rva, value):
        struct.pack_into("<I", sec, rva - sect_rva, value)

    export_rva = export_size = 0
    if exports:
        names = sorted(exports)
        export_rva = here()
        sec += bytes(40)
        dll_name_rva = here()
        sec += b"test.dll\0"
        funcs_rva = here()
        for _ in names:
            sec += struct.pack("<I", 0x2000)
        name_ptrs_rva = here()
        sec += bytes(4 * len(names))
        ordinals_rva = here()
        for i in range(len(names)):
            sec += struct.pack("<H", i)
        for i, name in enumerate(names):
            put_u32(name_ptrs_rva + 4 * i, here())
            sec += name.encode() + b"\0"
        struct.pack_into("<IIHHIIIIIII", sec, export_rva - sect_rva, 0, export_ts, 0, 0,
                         dll_name_rva, 1, len(names), len(names), funcs_rva, name_ptrs_rva, ordinals_rva)
        export_size = here() - export_rva

    import_rva = import_size = 0
    if imports:
        import_rva = here()
        sec += bytes(20 * (len(imports) + 1))
        import_size = here() - import_rva
        for d, (dll, entries) in enumerate(imports.items()):
            name_rva = here()
            sec += dll.encode() + b"\0"
            ilt_rva = here()
            sec += bytes(8 * (len(entries) + 1))
            for k, entry in enumerate(entries):
                if isinstance(entry, int):
                    value = (1 << 63) | entry
                else:
                    value = here()
                    sec += struct.pack("<H", 0) + entry.encode() + b"\0"
                struct.pack_into("<Q", sec, ilt_rva - sect_rva + 8 * k, value)
            struct.pack_into("<IIIII", sec, import_rva - sect_rva + 20 * d, ilt_rva, 0, 0, name_rva, ilt_rva)

    code_rva = here()
    sec += code
    virtual_size = len(sec)
    sec += bytes(-len(sec) % 0x200)

    hdr = bytearray(sect_off)
    hdr[0:2] = b"MZ"
    struct.pack_into("<I", hdr, 0x3C, 0x80)
    hdr[0x40:0x50] = DOS_STUB
    hdr[0x80:0x84] = b"PE\0\0"
    struct.pack_into("<HHIIIHH", hdr, 0x84, 0x8664, 1, timestamp, 0, 0, 240, 0x2022)
    opt = 0x98
    struct.pack_into("<H", hdr, opt, 0x20B)
    struct.pack_into("<I", hdr, opt + 16, code_rva)
    struct.pack_into("<Q", hdr, opt + 24, 0x180000000)
    struct.pack_into("<II", hdr, opt + 32, 0x1000, 0x200)
    struct.pack_into("<III", hdr, opt + 56, sect_rva + len(sec), sect_off, checksum)
    struct.pack_into("<H", hdr, opt + 68, 3)
    struct.pack_into("<I", hdr, opt + 108, 16)
    struct.pack_into("<II", hdr, opt + 112, export_rva, export_size)
    struct.pack_into("<II", hdr, opt + 120, import_rva, import_size)
    struct.pack_into("<8sIIIIIIHHI", hdr, opt + 240, b".data", virtual_size, sect_rva, len(sec),
                     sect_off, 0, 0, 0, 0, 0xC0000040)
    return bytes(hdr) + bytes(sec)


class Trees:
    """Two runtime roots, `ours` and `ref`, each holding a `Libraries/` folder."""

    def __init__(self, tmp):
        self.ours = Path(tmp) / "ours"
        self.ref = Path(tmp) / "ref"
        for root in (self.ours, self.ref):
            (root / "Libraries").mkdir(parents=True)

    def put(self, side, rel, data, executable=False):
        path = getattr(self, side) / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        if executable:
            path.chmod(0o755)
        return path

    def both(self, rel, data, executable=False):
        self.put("ours", rel, data, executable)
        self.put("ref", rel, data, executable)


def classes(result):
    return {(cls, rel) for cls, rel, _ in result.rows}


class CompareRuntimesTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.t = Trees(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def test_identical_trees_reproduce(self):
        self.t.both("Libraries/a.txt", b"same")
        self.t.both("Libraries/Wine/lib/x.dll", make_pe(exports=("a",)))
        result = compare(self.t.ours, self.t.ref, set())
        self.assertEqual(result.exit_code, 0)
        self.assertEqual(result.rows, [])
        self.assertEqual(result.counts["different"], 0)
        self.assertGreaterEqual(result.counts["identical"], 2)

    def test_path_only_on_one_side_is_different(self):
        self.t.both("Libraries/a.txt", b"same")
        self.t.put("ours", "Libraries/extra.txt", b"new")
        result = compare(self.t.ours, self.t.ref, set())
        self.assertEqual(result.exit_code, 1)
        self.assertIn(("only-in-ours", "Libraries/extra.txt"), classes(result))
        self.assertEqual(result.counts["only-in-ours"], 1)

    @unittest.skipUnless(os.name == "posix", "symlinks and exec bits need POSIX")
    def test_symlink_target_and_exec_bit_count(self):
        self.t.both("Libraries/lib/a", b"a")
        self.t.both("Libraries/lib/b", b"b")
        os.symlink("a", self.t.ours / "Libraries/lib/link")
        os.symlink("b", self.t.ref / "Libraries/lib/link")
        result = compare(self.t.ours, self.t.ref, set())
        self.assertEqual(result.exit_code, 1)
        self.assertIn(("different", "Libraries/lib/link"), classes(result))

        os.remove(self.t.ref / "Libraries/lib/link")
        os.symlink("a", self.t.ref / "Libraries/lib/link")
        self.t.put("ours", "Libraries/bin/tool", b"#!/bin/sh\n", executable=True)
        self.t.put("ref", "Libraries/bin/tool", b"#!/bin/sh\n", executable=False)
        result = compare(self.t.ours, self.t.ref, set())
        self.assertEqual(result.exit_code, 1)
        self.assertEqual(classes(result), {("different", "Libraries/bin/tool")})

    def test_pe_timestamps_only(self):
        self.t.put("ours", "Libraries/x.dll", make_pe(timestamp=1, exports=("a",)))
        self.t.put("ref", "Libraries/x.dll", make_pe(timestamp=2, checksum=7, export_ts=3, exports=("a",)))
        result = compare(self.t.ours, self.t.ref, set())
        self.assertEqual(classes(result), {("timestamps", "Libraries/x.dll")})
        self.assertEqual(result.exit_code, 0)

    def test_pe_code_byte_is_interface_not_timestamps(self):
        imports = {"KERNEL32.dll": ["GetProcAddress", 7]}
        self.t.put("ours", "Libraries/x.dll", make_pe(exports=("a",), imports=imports, code=b"\x90"))
        self.t.put("ref", "Libraries/x.dll", make_pe(exports=("a",), imports=imports, code=b"\xcc"))
        result = compare(self.t.ours, self.t.ref, set())
        self.assertEqual(classes(result), {("interface", "Libraries/x.dll")})
        self.assertEqual(result.exit_code, 2)

    def test_pe_export_change_is_different(self):
        self.t.put("ours", "Libraries/x.dll", make_pe(exports=("a",)))
        self.t.put("ref", "Libraries/x.dll", make_pe(exports=("a", "b")))
        result = compare(self.t.ours, self.t.ref, set())
        self.assertEqual(result.exit_code, 1)
        [(cls, rel, reason)] = result.rows
        self.assertEqual((cls, rel), ("different", "Libraries/x.dll"))
        self.assertTrue(reason.startswith("exports"), reason)
        self.assertIn("-b", reason)

    def test_text_difference_is_different_unless_expected(self):
        self.t.put("ours", "Libraries/x.txt", b"Ano wording\n")
        self.t.put("ref", "Libraries/x.txt", b"upstream wording\n")
        result = compare(self.t.ours, self.t.ref, set())
        self.assertEqual(result.exit_code, 1)
        self.assertEqual(classes(result), {("different", "Libraries/x.txt")})

        result = compare(self.t.ours, self.t.ref, {"Libraries/x.txt"})
        self.assertEqual(result.exit_code, 0)
        self.assertEqual(classes(result), {("expected", "Libraries/x.txt")})
        self.assertEqual(result.counts["expected"], 1)

    def test_macho_uses_interface(self):
        ours = self.t.put("ours", "Libraries/lib/a.dylib", b"\xcf\xfa\xed\xfe" + b"\x01" * 60)
        ref = self.t.put("ref", "Libraries/lib/a.dylib", b"\xcf\xfa\xed\xfe" + b"\x02" * 60)

        def same(path):
            return {"archs": ["x86_64"], "imports": ["_a"]}

        self.assertEqual(classify(ours, ref, macho_interface=same)[0], "interface")

        def differ(path):
            return {"archs": ["x86_64"], "imports": ["_a"] if path == ours else ["_a", "_zz_missing"]}

        cls, reason = classify(ours, ref, macho_interface=differ)
        self.assertEqual(cls, "different")
        self.assertTrue(reason.startswith("imports"), reason)
        self.assertIn("_zz_missing", reason)

    def test_main_writes_report_and_exit_code(self):
        self.t.both("Libraries/a.txt", b"same")
        self.t.put("ours", "Libraries/x.dll", make_pe(exports=("a",)))
        self.t.put("ref", "Libraries/x.dll", make_pe(exports=("a", "b")))
        report = Path(self._tmp.name) / "report.txt"
        with redirect_stdout(io.StringIO()):
            code = main([str(self.t.ours), str(self.t.ref), "--report", str(report)])
        self.assertEqual(code, 1)
        lines = report.read_text().splitlines()
        self.assertEqual(lines[0], "summary: identical=1 timestamps=0 interface=0 different=1 "
                                   "only-in-ours=0 only-in-reference=0 expected=0")
        self.assertTrue(lines[1].startswith("different\tLibraries/x.dll\texports"), lines[1])
        # A usage error must not look like "equivalent" (2) or "different" (1).
        with redirect_stdout(io.StringIO()), mock.patch("sys.stderr", io.StringIO()):
            self.assertEqual(main([str(self.t.ours)]), 3)
            self.assertEqual(main([str(self.t.ours / "Libraries"), str(self.t.ref)]), 3)


if __name__ == "__main__":
    unittest.main()
