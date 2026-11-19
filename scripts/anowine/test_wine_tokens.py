"""Tests for wine_tokens.py. Run: python3 -m unittest discover -s scripts/anowine -p 'test_*.py'"""
import contextlib
import io
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
                               ("WinExec\tnot-wine\ta\nwinecfg\talias\tb\nWinExec\tnot-wine\tc\n", 3),
                               ("SetEvent\tnot-wine\tnot a wine token\n", 1)):
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


PHRASE = "the Wine project authors"


def run_gate(tmp, files, allowlist):
    root = Path(tmp) / "Libraries"
    root.mkdir()
    for name, data in files.items():
        (root / name).write_bytes(data)
    allow = Path(tmp) / "allow.txt"
    allow.write_text(allowlist, encoding="utf-8")
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        code = wine_tokens.main([str(root), "--out", str(Path(tmp) / "t.tsv"), "--allowlist", str(allow), "--gate"])
    return code, out.getvalue()


class GateTests(unittest.TestCase):
    def test_gate_fails_on_wine(self):
        with tempfile.TemporaryDirectory() as tmp:
            code, out = run_gate(tmp, {"ano.dll": b"\x00__wine_dbg_output\x00"}, "")
            self.assertEqual(code, 1)
            self.assertIn("__wine_dbg_output", out)

    def test_gate_passes_allowlisted(self):
        with tempfile.TemporaryDirectory() as tmp:
            allow = ("WinExec\tnot-wine\tWindows API (Win + Exec)\n"
                     "RKNS_5TwineE\tnot-wine\tLLVM's Twine class\n")
            code, out = run_gate(tmp, {"ano.dll": b"\x00WinExec\x00\x01RKNS_5TwineE\x00"}, allow)
            self.assertEqual(code, 0, out)

    def test_license_phrase(self):
        data = b"\x01" + PHRASE.encode("utf-16-le") + b"\x00\x00" + PHRASE.encode("ascii") + b"\x00"
        self.assertEqual(tokens_in_bytes(data, phrases=(PHRASE,)), Counter())
        self.assertEqual(tokens_in_bytes(data), Counter({"Wine": 2}))
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "blob.bin"
            path.write_bytes(b"\x02" * 7 + data)
            for chunk in range(1, len(data) + 9):
                ascii_counts, utf16_counts = wine_tokens.tokens_in_file(path, chunk=chunk, phrases=(PHRASE,))
                self.assertEqual(ascii_counts + utf16_counts, Counter(), f"chunk={chunk}")
            good = Path(tmp) / "good.txt"
            good.write_text(f"{PHRASE}\tlicense\tWine's LGPL copyright line\n", encoding="utf-8")
            self.assertEqual(load_allowlist(good)[PHRASE][0], "license")
            code, out = run_gate(tmp, {"ano.dll": data}, good.read_text(encoding="utf-8"))
            self.assertEqual(code, 0, out)
            bad = Path(tmp) / "bad.txt"
            bad.write_text(f"# c\n{PHRASE}\tcode-only\tnot the repo URL\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, r"line 2\b"):
                load_allowlist(bad)

    def test_not_wine_phrase(self):
        # Unicode character names in ICU's data: the drink, not the project.
        # Only these contexts are allowed; a bare WINE elsewhere still fails.
        data = b"@CITY\x86@WINE\x86@DIST\x86@SACRIFICIAL WINEDDFF\x88B130 OIL,B \xa3B131 WINE,B \x03"
        allow = ("@WINE\tnot-wine\tUnicode name word list in ICU data\n"
                 "SACRIFICIAL WINE\tnot-wine\tUnicode name in ICU data\n"
                 "B131 WINE\tnot-wine\tUnicode name of Linear B ideogram B131 in ICU data\n")
        with tempfile.TemporaryDirectory() as tmp:
            code, out = run_gate(tmp, {"icudtl.dat": data}, allow)
            self.assertEqual(code, 0, out)
        with tempfile.TemporaryDirectory() as tmp:
            code, out = run_gate(tmp, {"icudtl.dat": data, "system.reg": b"WINE REGISTRY Version 2\n"}, allow)
            self.assertEqual(code, 1, out)
            self.assertIn("WINE\t1\tLibraries/system.reg", out)

    def test_alias_phrase(self):
        # The builtin mark Apple's D3DMetal DLLs carry, kept in ntdll as an alias.
        data = b"\x00Wine builtin DLL\x00\x01Ano builtin DLL\x00"
        with tempfile.TemporaryDirectory() as tmp:
            code, out = run_gate(tmp, {"ntdll.dll": data}, "Wine builtin DLL\talias\tApple's D3DMetal mark\n")
            self.assertEqual(code, 0, out)

    def test_repo_url_phrase(self):
        # In a font's name table the URL runs straight into the next record.
        url = "github.com/HighStormPVP/AnoWine"
        data = b"\x01https://" + url.encode() + b"A copy\x00" + f"https://{url}B".encode("utf-16-le")
        with tempfile.TemporaryDirectory() as tmp:
            code, out = run_gate(tmp, {"x.ttf": data}, f"{url}\tcode-only\tthe repo URL\n")
            self.assertEqual(code, 0, out)
            bad = Path(tmp) / "bad.txt"
            bad.write_text(f"{url}\tnot-wine\tnot the repo URL\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, r"line 1\b"):
                load_allowlist(bad)

    def test_license_phrase_beyond_ascii(self):
        # A font's copyright record: Mac Roman (the copyright sign is 0xA9, as
        # in Latin-1), UTF-16, and UTF-8 in text files.
        phrase = "WineSymbol © (Jon Parshall for CodeWeavers)"
        data = b"\x01".join(phrase.encode(enc) for enc in ("latin-1", "utf-16-le", "utf-8")) + b"\x00"
        self.assertEqual(tokens_in_bytes(data), Counter({"WineSymbol": 3}))
        self.assertEqual(tokens_in_bytes(data, phrases=(phrase,)), Counter())
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "font.ttf"
            path.write_bytes(data)
            for chunk in range(1, len(data) + 2):
                ascii_counts, utf16_counts = wine_tokens.tokens_in_file(path, chunk=chunk, phrases=(phrase,))
                self.assertEqual(ascii_counts + utf16_counts, Counter(), f"chunk={chunk}")


if __name__ == "__main__":
    unittest.main()
