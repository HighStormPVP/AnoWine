"""Tests for rename_sources.py. Run: python3 -m unittest discover -s scripts/anowine -p 'test_*.py'"""
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from rename_sources import load_rules, rename_path, rename_text, rename_tree  # noqa: E402

PROTECT = (
    "# text\tkind\treason\n"
    "winerror\tsubstring\tWindows header winerror.h (Win + error)\n"
    "WINERROR\tsubstring\tWindows header guard (Win + error)\n"
    "winevt\tsubstring\tWindows header winevt.h (Win + evt)\n"
    "winefs\tsubstring\tWindows header winefs.h (Win + EFS)\n"
    "WINEVENT\tsubstring\tWindows API WINEVENT_* (Win + event)\n"
    "intertwined\tword\tEnglish word\n"
    "twine\tword\tEnglish word\n"
    "the Wine project authors\tlicense\tLGPL copyright line\n"
)
MAP = (
    "winecfg\tano-cfg\tprogram\n"
    "winedbg\tano-dbg\tprogram\n"
    "org.winehq.wine\tio.github.highstormpvp.Ano.core\tidentity\n"
    "org.winehq.\tio.github.highstormpvp.Ano.\tidentity\n"
    "org/winehq/wine\tio/github/highstormpvp/Ano/core\tidentity\n"
    "org/winehq/\tio/github/highstormpvp/Ano/\tidentity\n"
    "bugs.winehq.org\thttps://github.com/HighStormPVP/AnoWine/issues\turl\n"
    "winehq.org\thttps://github.com/HighStormPVP/AnoWine\turl\n"
)


def rules_in(tmp):
    protect = Path(tmp) / "protect.txt"
    mapping = Path(tmp) / "map.txt"
    protect.write_text(PROTECT, encoding="utf-8")
    mapping.write_text(MAP, encoding="utf-8")
    return load_rules(protect, mapping)


class RenameTextTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.rules = rules_in(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def r(self, text):
        return rename_text(text, self.rules)

    def test_case_rule(self):
        self.assertEqual(self.r("wine Wine WINE"), "ano Ano ANO")
        self.assertEqual(self.r("WinExec WinEvent"), "WinExec WinEvent")
        self.assertEqual(self.r("__wine_dbg_output IWineDXGIDevice libwine"),
                         "__ano_dbg_output IAnoDXGIDevice libano")

    def test_protected(self):
        kept = 'WINEVENT_OUTOFCONTEXT HWINEVENTHOOK intertwined #include "winerror.h" winevt.h winefs.h'
        self.assertEqual(self.r(kept), kept)
        self.assertEqual(self.r("__WINE_WINERROR_H"), "__ANO_WINERROR_H")
        self.assertEqual(self.r("testwine"), "testano")
        self.assertEqual(self.r("Copyright the Wine project authors"), "Copyright the Wine project authors")
        self.assertEqual(self.r("Wine project"), "Ano project")

    def test_programs(self):
        self.assertEqual(self.r('"winecfg.exe"'), '"ano-cfg.exe"')
        self.assertEqual(self.r("programs/winedbg/"), "programs/ano-dbg/")
        self.assertEqual(self.r("winedbg_main"), "anodbg_main")
        self.assertEqual(self.r("WINEDBG"), "ANODBG")
        # After an escape inside a C string the name is still the program.
        self.assertEqual(self.r(r'"Usage:\n\twinedbg [options]"'), r'"Usage:\n\tano-dbg [options]"')

    def test_programs_in_code(self):
        # In C-family files a program name outside a string is an identifier
        # (a debug channel): the case rule keeps it a valid C name.
        code = ("WINE_DECLARE_DEBUG_CHANNEL(winedbg);\n"
                "/* don't start winedbg */ static const char *cmd = \"winedbg --auto %ld\";\n"
                "if (c == '\"') run(winecfg, L\"winecfg.exe\");\n")
        self.assertEqual(rename_text(code, self.rules, code=True),
                         "ANO_DECLARE_DEBUG_CHANNEL(anodbg);\n"
                         "/* don't start anodbg */ static const char *cmd = \"ano-dbg --auto %ld\";\n"
                         "if (c == '\"') run(anocfg, L\"ano-cfg.exe\");\n")

    def test_identity_and_urls(self):
        self.assertEqual(self.r("org.winehq.wine"), "io.github.highstormpvp.Ano.core")
        self.assertEqual(self.r("org.winehq.builtin.text"), "io.github.highstormpvp.Ano.builtin.text")
        self.assertEqual(self.r('"/org/winehq/wine/winebth/AuthAgent"'),
                         '"/io/github/highstormpvp/Ano/core/anobth/AuthAgent"')
        self.assertEqual(self.r('"https://bugs.winehq.org/show_bug.cgi?id=1"'),
                         '"https://github.com/HighStormPVP/AnoWine/issues"')
        self.assertEqual(self.r("see https://dl.winehq.org/wine/wine-mono/ now"),
                         "see https://github.com/HighStormPVP/AnoWine now")
        self.assertEqual(self.r("www.winehq.org"), "https://github.com/HighStormPVP/AnoWine")
        for text in ("https://www.winehq.org/", "http://source.winehq.org/x", "winehq.org"):
            self.assertNotIn("anohq", self.r(text))

    def test_paths(self):
        self.assertEqual(rename_path("dlls/winemac.drv/cocoa_window.m", self.rules), "dlls/anomac.drv/cocoa_window.m")
        self.assertEqual(rename_path("programs/winecfg/main.c", self.rules), "programs/ano-cfg/main.c")
        self.assertEqual(rename_path("include/winerror.h", self.rules), "include/winerror.h")


class RenameTreeTests(unittest.TestCase):
    def test_tree(self):
        with tempfile.TemporaryDirectory() as tmp:
            rules = rules_in(tmp)
            src = Path(tmp) / "src"
            files = {
                "dlls/winemac.drv/cocoa_window.m": "@interface WineWindow\n",
                "programs/winecfg/Makefile.in": "MODULE = winecfg.exe\n",
                "include/wine/debug.h": "#include \"winerror.h\"\n",
                "programs/winedbg/main.c": "WINE_DEFAULT_DEBUG_CHANNEL(winedbg);\nconst char *d = \"winedbg\";\n",
            }
            for rel, text in files.items():
                (src / rel).parent.mkdir(parents=True, exist_ok=True)
                (src / rel).write_text(text, encoding="utf-8")
            (src / "fonts").mkdir()
            (src / "fonts/x.ttf").write_bytes(b"\x00\x01\x00\x00" + "Wine".encode("utf-16-be"))

            report = rename_tree(src, rules)

            self.assertEqual((src / "dlls/anomac.drv/cocoa_window.m").read_text(encoding="utf-8"),
                             "@interface AnoWindow\n")
            self.assertEqual((src / "programs/ano-cfg/Makefile.in").read_text(encoding="utf-8"),
                             "MODULE = ano-cfg.exe\n")
            self.assertEqual((src / "include/ano/debug.h").read_text(encoding="utf-8"),
                             "#include \"winerror.h\"\n")
            self.assertEqual((src / "programs/ano-dbg/main.c").read_text(encoding="utf-8"),
                             "ANO_DEFAULT_DEBUG_CHANNEL(anodbg);\nconst char *d = \"ano-dbg\";\n")
            self.assertFalse((src / "dlls/winemac.drv").exists())
            self.assertIn("fonts/x.ttf", report.binary_with_wine)
            self.assertEqual(report.renamed_paths, 4)
            self.assertEqual(report.changed_files, 3)

            again = rename_tree(src, rules)
            self.assertEqual((again.renamed_paths, again.changed_files), (0, 0))

    def test_collision_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            rules_in(tmp)
            src = Path(tmp) / "src"
            for rel in ("dlls/winefoo/a.c", "dlls/anofoo/a.c"):
                (src / rel).parent.mkdir(parents=True, exist_ok=True)
                (src / rel).write_text("x\n", encoding="utf-8")
            result = subprocess.run(
                [sys.executable, os.path.join(HERE, "rename_sources.py"), str(src),
                 "--protect", str(Path(tmp) / "protect.txt"), "--map", str(Path(tmp) / "map.txt")],
                capture_output=True, text=True)
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn("dlls/anofoo", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
