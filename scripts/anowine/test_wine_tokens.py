"""Tests for wine_tokens.py. Run: python3 -m unittest discover -s scripts/anowine -p 'test_*.py'"""
import os
import sys
import tempfile
import unittest
from collections import Counter
from pathlib import Path

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import wine_tokens  # noqa: E402
from wine_tokens import classify_token, load_allowlist, tokens_in_bytes, tokens_in_name  # noqa: E402


class WineTokensTests(unittest.TestCase):
    def test_name_tokens(self):
        self.assertEqual(tokens_in_name("winecfg.exe"), ["winecfg"])
        self.assertEqual(tokens_in_name("libwine.dylib"), ["libwine"])
        self.assertEqual(tokens_in_name("wine-mono-11.3.0"), ["wine"])
        self.assertEqual(tokens_in_name("ano-boot.exe"), [])

    def test_ascii_and_utf16(self):
        data = b"\x00__wine_unix_call\x00" + "Wine builtin".encode("utf-16-le")
        self.assertEqual(tokens_in_bytes(data), Counter({"__wine_unix_call": 1, "Wine": 1}))

    def test_short_runs_ignored(self):
        self.assertEqual(tokens_in_bytes(b"wine"), Counter({"wine": 1}))
        self.assertEqual(tokens_in_bytes(b"win"), Counter())
        self.assertEqual(tokens_in_bytes(b"\x00win\x00e\x00"), Counter())

    def test_not_wine_candidates(self):
        for token in ("WinExec", "SetWinEventHook", "twine"):
            self.assertEqual(classify_token(token, {}), "not-wine-candidate", token)
        for token in ("WINEPREFIX", "libwine", "__wine_unix_call"):
            self.assertEqual(classify_token(token, {}), "wine", token)

    def test_allowlist(self):
        with tempfile.TemporaryDirectory() as tmp:
            good = Path(tmp) / "good.txt"
            good.write_text("# comment\n\nWinExec\tnot-wine\tWindows API WinExec (Win + Exec)\n")
            allow = load_allowlist(good)
            self.assertEqual(allow["WinExec"], ("not-wine", "Windows API WinExec (Win + Exec)"))
            self.assertEqual(classify_token("WinExec", allow), "allowlisted:not-wine")
            for body, line in (("# c\nWinExec\tnot-a-category\twhy\n", 2),
                               ("WinExec\tnot-wine\t\n", 1),
                               ("WinExec\tnot-wine\n", 1),
                               ("WinExec\tnot-wine\ta\nX\talias\tb\nWinExec\tnot-wine\tc\n", 3)):
                bad = Path(tmp) / "bad.txt"
                bad.write_text(body)
                with self.assertRaisesRegex(ValueError, rf"line {line}\b"):
                    load_allowlist(bad)

    def test_chunk_edges_do_not_cut_tokens(self):
        data = (b"\x01" * 5 + b"__wine_unix_call" + b"\x02" + "WineD3D".encode("utf-16-le")
                + b"\x00\x03libwine.dylib\x00\x05" + "Wine".encode("utf-16-le"))
        expected = tokens_in_bytes(data)
        self.assertEqual(expected, Counter({"__wine_unix_call": 1, "WineD3D": 1, "libwine": 1, "Wine": 1}))
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "blob.bin"
            path.write_bytes(data)
            for chunk in range(1, len(data) + 2):
                ascii_counts, utf16_counts = wine_tokens.tokens_in_file(path, chunk=chunk)
                self.assertEqual(ascii_counts + utf16_counts, expected, f"chunk={chunk}")


if __name__ == "__main__":
    unittest.main()
