"""Tests for rename_binaries.py. Run: python3 -m unittest discover -s scripts/anowine -p 'test_*.py'"""
import os
import sys
import tempfile
import unittest
from collections import Counter
from pathlib import Path

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from rename_binaries import rename_font, rename_padded  # noqa: E402
from rename_sources import load_rules  # noqa: E402
from wine_tokens import tokens_in_bytes  # noqa: E402

try:
    from fontTools.fontBuilder import FontBuilder
    from fontTools.pens.ttGlyphPen import TTGlyphPen
    from fontTools.ttLib import TTFont
    from fontTools.ttLib.tables.DefaultTable import DefaultTable
except ImportError:  # the Hygiene workflow installs it; skipped elsewhere
    FontBuilder = None

COPYRIGHT = "WineSymbol © (Jon Parshall for CodeWeavers). 2009."
LICENSE = "A copy of the LGPL is included in the Wine distribution in the file COPYING.LIB."
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
        builder.setupHead(created=1, modified=2)
        bdf = DefaultTable("BDF ")
        bdf.data = b"\x00\x01\x00\x00FONT_NAME\x00WineTahoma\x00FACE_NAME\x00Tahoma\x00"
        builder.font["BDF "] = bdf
        builder.save(path)

    def test_font_names_vendor_and_bdf(self):
        with tempfile.TemporaryDirectory() as tmp:
            rules = rules_in(tmp)
            path = Path(tmp) / "tahoma.ttf"
            self.make_font(path)
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
            self.assertEqual(font["head"].modified, 2)
            left = tokens_in_bytes(path.read_bytes(), phrases=("WineSymbol © (Jon Parshall for CodeWeavers)",
                                                               "Wine distribution in the file COPYING.LIB"))
            self.assertEqual(set(left), {"AnoWine"})


if __name__ == "__main__":
    unittest.main()
