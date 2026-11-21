"""Tests for check_app_runtime_names.py. Run: python3 -m unittest discover -s scripts/anowine -p 'test_*.py'"""
import os
import sys
import tempfile
import unittest
from pathlib import Path

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from check_app_runtime_names import scan  # noqa: E402


def tree(tmp, files):
    root = Path(tmp)
    for rel, text in files.items():
        (root / rel).parent.mkdir(parents=True, exist_ok=True)
        (root / rel).write_text(text, encoding="utf-8")
    return root


class LintTests(unittest.TestCase):
    def names(self, swift="", json=None):
        files = {"WhiskyKit/Sources/WhiskyKit/Wine/Sample.swift": swift}
        if json is not None:
            files["WhiskyKit/Sources/WhiskyKit/Diagnostics/Resources/patterns.json"] = json
        with tempfile.TemporaryDirectory() as tmp:
            return [(hit.line, hit.rule) for hit in scan(tree(tmp, files))]

    def test_environment_variables(self):
        swift = 'env["WINEPREFIX"] = p\nlet a = "WINE"\nlet b = "WINE_LARGE_ADDRESS_AWARE"\nlet c = "ANO_WINE_DIR"\n'
        self.assertEqual(self.names(swift), [(1, "variable"), (2, "variable"), (3, "variable"), (4, "variable")])

    def test_registry_and_folders(self):
        swift = ('let k = "HKCU\\\\Software\\\\Wine\\\\DllOverrides"\n'
                 'let u = lib.appending(path: "Wine").appending(path: "bin")\n'
                 'let v = root.appending(path: "lib").appending(path: "wine")\n'
                 'let w = "Libraries/Wine/lib/wine/x86_64-windows"\n')
        self.assertEqual(self.names(swift), [(1, "registry"), (2, "folder"), (3, "folder"), (4, "folder")])

    def test_programs_modules_and_files(self):
        swift = ('run("winecfg", ["-v"])\nlet d = "winemetal.dll"\nlet o = "winemetal"\nlet b = "wined3d"\n'
                 'let p = "WhiskyWineVersion"\nlet t = "winetricks"\nlet l = "winetricks.log"\n')
        self.assertEqual(self.names(swift), [(1, "program"), (2, "module"), (3, "module"), (4, "module"),
                                             (5, "file"), (6, "file"), (7, "file")])

    def test_engine_output(self):
        swift = 'if line.hasPrefix("wine-") {}\nlet r = #"^wine:"#\n'
        self.assertEqual(self.names(swift, json='{"pattern": "wine: Unhandled page fault"}\n'),
                         [(1, "engine output"), (2, "engine output"), (1, "engine output")])

    def test_builtin_mark(self):
        swift = 'let m = "Wine builtin DLL"\nlet n = "Wine builtin DLL" // old name: Apple\'s D3DMetal DLLs carry it\n'
        self.assertEqual(self.names(swift), [(1, "mark")])

    def test_comments_identifiers_and_text_are_not_runtime_names(self):
        swift = ('// WINEPREFIX in a comment\n/* Software\\\\Wine */\nstruct WineEnvironment {}\n'
                 'let s = String(localized: "winetricks.error.missingResources")\nlet u = "Open Wine Configuration"\n'
                 'let k = "wineConfig"\nlet ok = "ANOPREFIX"\nlet q = "ano-cfg"\nImage(systemName: "wineglass")\n')
        self.assertEqual(self.names(swift), [])

    def test_old_name_marker_allows_a_line(self):
        swift = 'if header.hasPrefix("WINE REGISTRY") { old = true } // old name: recognises a bottle from runtime 4.x\n'
        self.assertEqual(self.names(swift), [])

    def test_tests_are_not_scanned(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = tree(tmp, {"WhiskyKit/Tests/WhiskyKitTests/X.swift": 'let a = "WINEPREFIX"\n'})
            self.assertEqual(list(scan(root)), [])


if __name__ == "__main__":
    unittest.main()
