"""Tests for rename_binaries.py. Run: python3 -m unittest discover -s scripts/anowine -p 'test_*.py'"""
import contextlib
import hashlib
import io
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from collections import Counter
from pathlib import Path

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from rename_binaries import main, rename_font, rename_msi, rename_padded, rename_pe  # noqa: E402
from rename_sources import load_rules  # noqa: E402
from wine_tokens import tokens_in_bytes  # noqa: E402

try:
    from fontTools.fontBuilder import FontBuilder
    from fontTools.pens.ttGlyphPen import TTGlyphPen
    from fontTools.ttLib import TTFont
    from fontTools.ttLib.tables.DefaultTable import DefaultTable
except ImportError:  # the Hygiene workflow installs it; skipped elsewhere
    FontBuilder = None

COPYRIGHT_PHRASE = "WineSymbol © (Jon Parshall for CodeWeavers)"
LICENSE_PHRASE = "Wine distribution in the file COPYING.LIB"
COPYRIGHT = COPYRIGHT_PHRASE + ". 2009."
LICENSE = f"A copy of the LGPL is included in the {LICENSE_PHRASE}."
PROTECT = (
    "WineSymbol © (Jon Parshall for CodeWeavers)\tlicense\tthe Symbol font's copyright line\n"
    "Wine distribution in the file COPYING.LIB\tlicense\tLGPL notice\n"
)
MAP = "winehq.org\thttps://github.com/HighStormPVP/AnoWine\turl\n"
REPO = "https://github.com/HighStormPVP/AnoWine"


def rules_in(tmp):
    protect = Path(tmp) / "protect.txt"
    mapping = Path(tmp) / "map.txt"
    protect.write_text(PROTECT, encoding="utf-8")
    mapping.write_text(MAP, encoding="utf-8")
    return load_rules(protect, mapping)


class PaddedTests(unittest.TestCase):
    def test_strings_are_renamed_in_place(self):
        with tempfile.TemporaryDirectory() as tmp:
            rules = rules_in(tmp)
        data = b"\x05\x00Wine placeholder BINK resource\x00\x00\x07WinExec\x00FONT_NAME\x00WineTahoma\x00"
        out = rename_padded(data, rules)
        self.assertEqual(out, b"\x05\x00Ano placeholder BINK resource\x00\x00\x00\x07WinExec\x00"
                              b"FONT_NAME\x00AnoTahoma\x00\x00")
        self.assertEqual(len(out), len(data))

    def test_a_longer_string_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            rules = rules_in(tmp)
        with self.assertRaisesRegex(ValueError, "winehq"):
            rename_padded(b"\x01http://www.winehq.org\x00", rules)


@unittest.skipIf(FontBuilder is None, "fontTools is not installed")
class FontTests(unittest.TestCase):
    def make_font(self, path):
        builder = FontBuilder(1000, isTTF=True)
        builder.setupGlyphOrder([".notdef"])
        builder.setupCharacterMap({})
        builder.setupGlyf({".notdef": TTGlyphPen(None).glyph()})
        builder.setupHorizontalMetrics({".notdef": (500, 0)})
        builder.setupHorizontalHeader(ascent=800, descent=-200)
        builder.setupNameTable({"copyright": COPYRIGHT, "familyName": "Tahoma", "styleName": "Regular",
                                "fullName": "Wine Tahoma Regular", "psName": "WineTahoma",
                                "manufacturer": "Wine", "vendorURL": "http://www.winehq.org",
                                "licenseDescription": LICENSE}, mac=True)
        builder.setupOS2(achVendID="Wine")
        builder.setupPost()
        bdf = DefaultTable("BDF ")
        bdf.data = b"\x00\x01\x00\x00FONT_NAME\x00WineTahoma\x00FACE_NAME\x00Tahoma\x00"
        builder.font["BDF "] = bdf
        builder.save(path)

    def test_font_names_vendor_and_bdf(self):
        with tempfile.TemporaryDirectory() as tmp:
            rules = rules_in(tmp)
            path = Path(tmp) / "tahoma.ttf"
            self.make_font(path)
            modified = TTFont(path)["head"].modified
            rename_font(path, rules)
            font = TTFont(path)
            for platform in (1, 3):
                names = {r.nameID: r.toUnicode() for r in font["name"].names if r.platformID == platform}
                self.assertEqual(names[0], COPYRIGHT)
                self.assertEqual(names[1], "Tahoma")
                self.assertEqual(names[4], "Ano Tahoma Regular")
                self.assertEqual(names[6], "AnoTahoma")
                self.assertEqual(names[8], "Ano")
                self.assertEqual(names[11], REPO)
                self.assertEqual(names[13], LICENSE)
            self.assertEqual(font["OS/2"].achVendID, "Ano ")
            self.assertEqual(font["BDF "].data, b"\x00\x01\x00\x00FONT_NAME\x00AnoTahoma\x00\x00FACE_NAME\x00Tahoma\x00")
            self.assertEqual(font["head"].modified, modified)
            # Name records are stored back to back, so the repo URL runs into the
            # next record's text; the allowlist names the URL, not the token.
            left = tokens_in_bytes(path.read_bytes(), phrases=(COPYRIGHT_PHRASE, LICENSE_PHRASE,
                                                               "github.com/HighStormPVP/AnoWine"))
            self.assertEqual(left, Counter())


MONO_PROTECT = (
    "WineMono\tsubstring\twine-mono's assembly names (mono-internal)\n"
    "winexe\tsubstring\tthe C# target kind (Win + exe)\n"
    "WINEVENT\tsubstring\tWindows API WINEVENT_* (Win + event)\n"
)


def make_pe(exports, section_extra=b""):
    """A small PE32+ DLL: one .rdata section holding an export directory whose
    names are sorted, as a linker writes them; export i's function is at
    0x2000 + 16 * i, in the order given."""
    va, raw = 0x1000, 0x200
    order = sorted(range(len(exports)), key=lambda i: exports[i].encode())
    n = len(exports)
    funcs_at, names_at = 40, 40 + 4 * n
    ords_at = names_at + 4 * n
    strings_at = ords_at + 2 * n
    blob, name_rvas = b"", []
    for i in order:
        name_rvas.append(va + strings_at + len(blob))
        blob += exports[i].encode() + b"\x00"
    dll_name_rva = va + strings_at + len(blob)
    blob += b"test.dll\x00"
    section = bytearray(40)
    struct.pack_into("<IIIIIII", section, 12, dll_name_rva, 1, n, n,
                     va + funcs_at, va + names_at, va + ords_at)
    section += b"".join(struct.pack("<I", 0x2000 + 16 * i) for i in range(n))
    section += b"".join(struct.pack("<I", rva) for rva in name_rvas)
    section += b"".join(struct.pack("<H", i) for i in order)
    section += blob + section_extra
    section += b"\x00" * (-len(section) % 0x200)
    pe = bytearray(raw)
    pe[0:2] = b"MZ"
    struct.pack_into("<I", pe, 0x3C, 0x80)
    pe[0x80:0x84] = b"PE\x00\x00"
    struct.pack_into("<HHIIIHH", pe, 0x84, 0x8664, 1, 0, 0, 0, 240, 0x2022)
    opt = 0x98
    struct.pack_into("<H", pe, opt, 0x20B)
    struct.pack_into("<I", pe, opt + 108, 16)
    struct.pack_into("<II", pe, opt + 112, va, strings_at + len(blob))
    struct.pack_into("<8sIIII", pe, opt + 240, b".rdata", len(section), va, len(section), raw)
    return bytes(pe) + bytes(section)


def read_exports(data):
    """(name, function RVA) in the order of the export name table."""
    opt = struct.unpack_from("<I", data, 0x3C)[0] + 24
    va, raw = struct.unpack_from("<II", data, opt + 240 + 12)[0], struct.unpack_from("<I", data, opt + 240 + 20)[0]
    exp_rva = struct.unpack_from("<I", data, opt + 112)[0]

    def at(rva):
        return rva - va + raw
    _, n_names, funcs, names, ords = struct.unpack_from("<IIIII", data, at(exp_rva) + 20)
    out = []
    for i in range(n_names):
        name_off = at(struct.unpack_from("<I", data, at(names) + 4 * i)[0])
        ordinal = struct.unpack_from("<H", data, at(ords) + 2 * i)[0]
        out.append((data[name_off:data.index(b"\x00", name_off)].decode(),
                    struct.unpack_from("<I", data, at(funcs) + 4 * ordinal)[0]))
    return out


class PeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        protect = Path(self.tmp.name) / "protect.txt"
        mapping = Path(self.tmp.name) / "map.txt"
        protect.write_text(MONO_PROTECT, encoding="utf-8")
        mapping.write_text("winemsibuilder\tano-msibuilder\tprogram\n", encoding="utf-8")
        self.rules = load_rules(protect, mapping)

    def tearDown(self):
        self.tmp.cleanup()

    def test_exports_resorted(self):
        data = make_pe(["mono_a", "wine_mono_hook", "zlib_x"])
        self.assertEqual(read_exports(data), [("mono_a", 0x2000), ("wine_mono_hook", 0x2010), ("zlib_x", 0x2020)])
        new = rename_pe(data, self.rules)
        self.assertEqual(len(new), len(data))
        # Wine looks exports up by binary search: the table must stay sorted.
        self.assertEqual(read_exports(new), [("ano_mono_hook", 0x2010), ("mono_a", 0x2000), ("zlib_x", 0x2020)])

    def test_path_keeps_length(self):
        path = "/builds/mono/wine-mono/wine-mono-11.3.0/mono/x.c"
        want = "/builds/mono/ano-mono//ano-mono-11.3.0//mono/x.c"
        for data, expected in ((b"\x01" + path.encode() + b"\x00", b"\x01" + want.encode() + b"\x00"),
                               # a .NET user string: UTF-16 with a length, no NUL
                               (b"\x63" + path.encode("utf-16-le") + b"\x01", b"\x63" + want.encode("utf-16-le") + b"\x01")):
            self.assertEqual(rename_pe(data, self.rules), expected)

    def test_terminated_strings(self):
        data = (b"\x02Wine builtin DLL\x00\x03__wine_dbg_output\x00\x04"
                + "WINEDEBUG".encode("utf-16-le") + b"\x00\x00")
        self.assertEqual(rename_pe(data, self.rules),
                         b"\x02Ano builtin DLL\x00\x00\x03__ano_dbg_output\x00\x00\x04"
                         + "ANODEBUG".encode("utf-16-le") + b"\x00\x00\x00\x00")

    def test_protected(self):
        data = (b"\x01WineMono.I18N.dll\x00\x02/target:winexe\x00\x03SetWinEventHook\x00"
                + "WineMono.Posix, Version=4.0.0.0".encode("utf-16-le") + b"\x05")
        self.assertEqual(rename_pe(data, self.rules), data)

    def test_unterminated_change_refused(self):
        data = b"\x01" + "Wine Mono Runtime".encode("utf-16-le") + b"\x07\x01"
        with self.assertRaisesRegex(ValueError, r"offset 0x1\b"):
            rename_pe(data, self.rules)


class TreeTests(unittest.TestCase):
    """--tree: a tree we cannot rebuild, text files and PE files in one pass."""

    def run_tree(self, tmp, protect):
        root = Path(tmp)
        (root / "protect.txt").write_text(protect, encoding="utf-8")
        (root / "map.txt").write_text("winemsibuilder\tano-msibuilder\tprogram\n", encoding="utf-8")
        src = root / "src"
        files = {
            "wine-mono-1.0/bin/libmono.dll": make_pe(["mono_a", "wine_mono_hook"], b"WINEVENT_X\x00Wine builtin DLL\x00"),
            "wine-mono-1.0/lib/WineMono.Posix.dll": b"MZ\x00\x01WineMono.Posix\x00",
            "wine-mono-1.0/support/x.inf": b"[WineFakeDlls]\n; target winexe\n",
        }
        for rel, data in files.items():
            (src / rel).parent.mkdir(parents=True, exist_ok=True)
            (src / rel).write_bytes(data)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = main(["--protect", str(root / "protect.txt"), "--map", str(root / "map.txt"), "--tree", str(src)])
        return code, out.getvalue(), src

    def test_tree(self):
        with tempfile.TemporaryDirectory() as tmp:
            code, out, src = self.run_tree(tmp, MONO_PROTECT)
            self.assertEqual(code, 0, out)
            mono = src / "ano-mono-1.0"
            self.assertEqual([name for name, _ in read_exports((mono / "bin/libmono.dll").read_bytes())],
                             ["ano_mono_hook", "mono_a"])
            self.assertIn(b"WINEVENT_X\x00Ano builtin DLL\x00\x00", (mono / "bin/libmono.dll").read_bytes())
            self.assertEqual((mono / "lib/WineMono.Posix.dll").read_bytes(), b"MZ\x00\x01WineMono.Posix\x00")
            self.assertEqual((mono / "support/x.inf").read_text(encoding="utf-8"), "[AnoFakeDlls]\n; target winexe\n")

    def test_unused_protected_text_fails(self):
        # Each entry must be used by one of the passes, text or PE.
        with tempfile.TemporaryDirectory() as tmp:
            code, out, _ = self.run_tree(tmp, MONO_PROTECT + "swine\tword\tEnglish word\n")
            self.assertEqual(code, 1, out)
            self.assertIn("unused protected text\tswine", out)


HAVE_MSITOOLS = all(shutil.which(tool) for tool in ("msibuild", "msiinfo", "gcab"))
IDT = {  # a small installer shaped like wine-mono's support MSI
    "Property": "Property\tValue\ns72\tl0\nProperty\tProperty\n"
                "ProductName\tWine Mono Windows Support\nManufacturer\tThe Wine Project\nProductVersion\t1.0\n",
    "Feature": "Feature\tFeature_Parent\tTitle\tDescription\tDisplay\tLevel\tDirectory_\tAttributes\n"
               "s38\tS38\tL64\tL255\tI2\ti2\tS72\ti2\nFeature\tFeature\nwine_mono\t\t\t\t\t1\t\t0\n",
    "FeatureComponents": "Feature_\tComponent_\ns38\ts72\nFeatureComponents\tFeature_\tComponent_\n"
                         "wine_mono\tnet\n",
    "InstallExecuteSequence": "Action\tCondition\tSequence\ns72\tS255\tI2\nInstallExecuteSequence\tAction\n"
                              "SetX\t(&wine_mono=3)\t100\n",
    "Media": "DiskId\tLastSequence\tDiskPrompt\tCabinet\tVolumeLabel\tSource\ni2\ti4\tL64\tS255\tS32\tS72\n"
             "Media\tDiskId\n1\t2\t\twinemono-support.cab\t\t\n",
    "File": "File\tComponent_\tFileName\tFileSize\tVersion\tLanguage\tAttributes\tSequence\n"
            "s72\ts72\tl255\ti4\tS72\tS20\tI2\ti2\nFile\tFile\n"
            "Microsoft.NET\\Framework\\installutil.exe\tnet\tinstallutil.exe\t{size}\t\t\t\t1\n"
            "Microsoft.NET\\Framework\\machine.config\tnet\tmachine.config\t{csize}\t\t\t\t2\n",
    "MsiFileHash": "File_\tOptions\tHashPart1\tHashPart2\tHashPart3\tHashPart4\ns72\ti2\ti4\ti4\ti4\ti4\n"
                   "MsiFileHash\tFile_\n"
                   "Microsoft.NET\\Framework\\installutil.exe\t0\t1\t2\t3\t4\n"
                   "Microsoft.NET\\Framework\\machine.config\t0\t{c1}\t{c2}\t{c3}\t{c4}\n",
    "_SummaryInformation": "PropertyId\tValue\ni2\tl255\n_SummaryInformation\tPropertyId\n"
                           "2\tWine Mono Windows Support Installation Database\n4\tThe Wine Project\n"
                           "5\tInstaller, Wine, Mono\n18\twinemsibuilder\n",
}


def md5_parts(data):
    return struct.unpack("<4i", hashlib.md5(data).digest())


def msi_rows(msi, table):
    out = subprocess.run(["msiinfo", "export", str(msi), table], capture_output=True, text=True, check=True).stdout
    return [line.split("\t") for line in out.splitlines()[3:]]


@unittest.skipUnless(HAVE_MSITOOLS, "needs msitools and gcab (the Hygiene workflow installs them)")
class MsiTests(unittest.TestCase):
    def test_msi_and_cabinet_renamed(self):
        exe = make_pe(["main"], b"/builds/mono/wine-mono/wine-mono-11.3.0/mono/x.cs\x00")
        config = b'<add name="md2" type="Mono.MD2, WineMono.Security, Version=4.0.0.0"/>\n'
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "protect.txt").write_text(MONO_PROTECT, encoding="utf-8")
            (root / "map.txt").write_text("winemsibuilder\tano-msibuilder\tprogram\n", encoding="utf-8")
            rules = load_rules(root / "protect.txt", root / "map.txt")
            files = root / "files"
            (files / "Microsoft.NET/Framework").mkdir(parents=True)
            (files / "Microsoft.NET/Framework/installutil.exe").write_bytes(exe)
            (files / "Microsoft.NET/Framework/machine.config").write_bytes(config)
            support = root / "support"
            support.mkdir()
            subprocess.run(["gcab", "-c", "-z", str(support / "anomono-support.cab"),
                            "Microsoft.NET/Framework/installutil.exe", "Microsoft.NET/Framework/machine.config"],
                           cwd=files, check=True)
            c1, c2, c3, c4 = md5_parts(config)
            for table, text in IDT.items():
                (root / f"{table}.idt").write_text(text.format(size=len(exe), csize=len(config),
                                                               c1=c1, c2=c2, c3=c3, c4=c4), encoding="utf-8")
            msi = support / "anomono-support.msi"
            for table in IDT:
                subprocess.run(["msibuild", str(msi), "-i", f"{table}.idt"], cwd=root, check=True)

            changes = rename_msi(msi, rules)

            self.assertTrue(changes)
            self.assertEqual(msi_rows(msi, "Feature")[0][0], "ano_mono")
            self.assertEqual(msi_rows(msi, "FeatureComponents")[0][0], "ano_mono")
            self.assertEqual(msi_rows(msi, "InstallExecuteSequence")[0][1], "(&ano_mono=3)")
            self.assertEqual(msi_rows(msi, "Media")[0][3], "anomono-support.cab")
            self.assertIn(["ProductName", "Ano Mono Windows Support"], msi_rows(msi, "Property"))
            self.assertIn(["Manufacturer", "The Ano Project"], msi_rows(msi, "Property"))
            summary = subprocess.run(["msiinfo", "suminfo", str(msi)], capture_output=True, text=True).stdout
            self.assertNotRegex(summary.lower(), "wine")
            # The cabinet: installutil.exe renamed at the same length, its hash
            # recomputed; machine.config's assembly name is mono-internal.
            out = root / "out"
            out.mkdir()
            subprocess.run(["gcab", "-x", "-C", str(out), str(support / "anomono-support.cab")], check=True)
            new_exe = (out / "Microsoft.NET/Framework/installutil.exe").read_bytes()
            self.assertEqual(len(new_exe), len(exe))
            self.assertIn(b"/builds/mono/ano-mono//ano-mono-11.3.0//mono/x.cs\x00", new_exe)
            self.assertEqual((out / "Microsoft.NET/Framework/machine.config").read_bytes(), config)
            hashes = {row[0]: tuple(int(x) for x in row[2:6]) for row in msi_rows(msi, "MsiFileHash")}
            self.assertEqual(hashes["Microsoft.NET\\Framework\\installutil.exe"], md5_parts(new_exe))
            self.assertEqual(hashes["Microsoft.NET\\Framework\\machine.config"], md5_parts(config))


if __name__ == "__main__":
    unittest.main()
