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


def make_pe(timestamp=0, checksum=0, export_ts=0, exports=(), imports=None, code=b"\x90", build_id=None):
    """A minimal PE32+ DLL (machine 0x8664) with one section at RVA 0x1000.

    `imports` maps a DLL name to a list of names (str) or ordinals (int);
    `build_id` (16 bytes) adds a CodeView debug entry, as `ld --build-id` writes."""
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

    debug_rva = 0
    if build_id is not None:
        debug_rva = here()
        sec += bytes(28)
        cv_rva = here()
        sec += b"RSDS" + build_id + struct.pack("<I", 1) + b"\0"
        struct.pack_into("<IIHHIIII", sec, debug_rva - sect_rva, 0, 0, 0, 0, 2, 25, cv_rva,
                         sect_off + cv_rva - sect_rva)

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
    struct.pack_into("<II", hdr, opt + 160, debug_rva, 28 if debug_rva else 0)
    struct.pack_into("<8sIIIIIIHHI", hdr, opt + 240, b".data", virtual_size, sect_rva, len(sec),
                     sect_off, 0, 0, 0, 0, 0xC0000040)
    return bytes(hdr) + bytes(sec)


def make_macho(code=b"\x90", oso_mtime=0, uuid=bytes(16), signature=b"sig"):
    """A minimal thin x86_64 Mach-O dylib: LC_UUID, LC_SYMTAB with one N_OSO
    entry (an object file and its modification time, as ld64 writes for code
    built with -g) and LC_CODE_SIGNATURE."""
    header_size, cmds_size = 32, 24 + 24 + 16
    code_off = header_size + cmds_size
    sym_off = code_off + len(code)
    strings = b"\0/build/a.o\0"
    str_off = sym_off + 16
    sig_off = str_off + len(strings)
    out = struct.pack("<IiiIIIII", 0xFEEDFACF, 0x01000007, 3, 6, 3, cmds_size, 0, 0)
    out += struct.pack("<II", 0x1B, 24) + uuid
    out += struct.pack("<IIIIII", 0x2, 24, sym_off, 1, str_off, len(strings))
    out += struct.pack("<IIII", 0x1D, 16, sig_off, len(signature))
    out += code
    out += struct.pack("<IBBHQ", 1, 0x66, 0, 1, oso_mtime)
    out += strings + signature
    return out


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

    def test_pe_build_id_is_a_timestamp(self):
        # ld's build ID hashes the link output, export timestamp included.
        ours = self.t.put("ours", "Libraries/x.dll", make_pe(timestamp=1, export_ts=1, exports=("a",),
                                                             build_id=b"A" * 16))
        ref = self.t.put("ref", "Libraries/x.dll", make_pe(timestamp=2, export_ts=2, exports=("a",),
                                                           build_id=b"B" * 16))
        self.assertEqual(classify(ours, ref)[0], "timestamps")
        ref = self.t.put("ref", "Libraries/x.dll", make_pe(exports=("a",), build_id=b"B" * 16, code=b"\xcc"))
        self.assertEqual(classify(ours, ref)[0], "interface")

    def test_macho_object_times_uuid_and_signature_are_timestamps(self):
        ours = self.t.put("ours", "Libraries/lib/a.so", make_macho(oso_mtime=1, uuid=b"A" * 16, signature=b"sA"))
        ref = self.t.put("ref", "Libraries/lib/a.so", make_macho(oso_mtime=2, uuid=b"B" * 16, signature=b"sB"))

        def no_tools(path):
            raise AssertionError("the interface is not needed for timestamps")

        self.assertEqual(classify(ours, ref, macho_interface=no_tools),
                         ("timestamps", "Mach-O object times, UUID or signature only"))

        ref = self.t.put("ref", "Libraries/lib/a.so", make_macho(code=b"\xcc", oso_mtime=2, uuid=b"B" * 16))

        def differ(path):
            return {"archs": ["x86_64"], "identifier": "a-1" if path == ours else "a-2"}

        self.assertEqual(classify(ours, ref, macho_interface=differ)[0], "different")

    def test_explained_interface_is_expected(self):
        # A file whose interface-only difference was explained by hand (Plan 3b:
        # FAudio's stray export table) passes; any other interface row still exits 2.
        imports = {"KERNEL32.dll": ["GetProcAddress", 7]}
        for name in ("x.dll", "y.dll"):
            self.t.put("ours", f"Libraries/{name}", make_pe(exports=("a",), imports=imports, code=b"\x90"))
            self.t.put("ref", f"Libraries/{name}", make_pe(exports=("a",), imports=imports, code=b"\xcc"))
        result = compare(self.t.ours, self.t.ref, set(), {"Libraries/x.dll": "stray export table"})
        self.assertEqual(classes(result), {("expected", "Libraries/x.dll"), ("interface", "Libraries/y.dll")})
        self.assertIn(("expected", "Libraries/x.dll", "explained interface: stray export table"), result.rows)
        self.assertEqual(result.exit_code, 2)
        explained = {"Libraries/x.dll": "stray export table", "Libraries/y.dll": "stray export table"}
        self.assertEqual(compare(self.t.ours, self.t.ref, set(), explained).exit_code, 0)
        # An explanation never excuses a real difference.
        self.t.put("ours", "Libraries/z.dll", make_pe(exports=("a",)))
        self.t.put("ref", "Libraries/z.dll", make_pe(exports=("a", "b")))
        result = compare(self.t.ours, self.t.ref, set(), {**explained, "Libraries/z.dll": "stray"})
        self.assertIn("different", {cls for cls, rel, _ in result.rows if rel == "Libraries/z.dll"})
        self.assertEqual(result.exit_code, 1)

    def test_main_reads_explained_interface_file(self):
        imports = {"KERNEL32.dll": ["GetProcAddress", 7]}
        self.t.put("ours", "Libraries/x.dll", make_pe(exports=("a",), imports=imports, code=b"\x90"))
        self.t.put("ref", "Libraries/x.dll", make_pe(exports=("a",), imports=imports, code=b"\xcc"))
        listing = Path(self._tmp.name) / "explained.txt"
        listing.write_text("# path<TAB>reason\n\nLibraries/x.dll\tstray export table\n", encoding="utf-8")
        with redirect_stdout(io.StringIO()):
            self.assertEqual(main([str(self.t.ours), str(self.t.ref), "--explained-interface", str(listing)]), 0)
        listing.write_text("Libraries/x.dll without a reason\n", encoding="utf-8")
        with redirect_stdout(io.StringIO()), mock.patch("sys.stderr", io.StringIO()):
            self.assertEqual(main([str(self.t.ours), str(self.t.ref), "--explained-interface", str(listing)]), 3)

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
