"""Tests for check_app_text.py. Run: python3 -m unittest discover -s scripts/anowine -p 'test_*.py'"""
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from check_app_text import scan, strip_interpolations  # noqa: E402


def tree(tmp, files):
    root = Path(tmp)
    for rel, text in files.items():
        (root / rel).parent.mkdir(parents=True, exist_ok=True)
        (root / rel).write_text(text, encoding="utf-8")
    return root


def hits(files):
    with tempfile.TemporaryDirectory() as tmp:
        return [(hit.path, hit.where) for hit in scan(tree(tmp, files))]


class InterpolationTests(unittest.TestCase):
    def test_interpolations_are_code(self):
        self.assertEqual(strip_interpolations(r'Version \(bottle.settings.wineVersion) of \(f(x, (y)))'),
                         "Version  of ")
        self.assertEqual(strip_interpolations(r'raw \#(wineName) text'), "raw  text")


class CheckTests(unittest.TestCase):
    def test_swift_literals(self):
        swift = ('let a = "Open Wine Configuration"\n'
                 'let b = "Version \\(settings.wineVersion)"\n'
                 '// Wine in a comment\n'
                 'struct WineEnvironment {}\n'
                 'let c = "WINE REGISTRY" // old name: recognises an earlier bottle\n'
                 'Logger(subsystem: id, category: "WineKit")\n')
        self.assertEqual(hits({"Whisky/Views/A.swift": swift}),
                         [("Whisky/Views/A.swift", "1"), ("Whisky/Views/A.swift", "6")])

    def test_the_repo_url_stays_but_github_io_does_not(self):
        # The repo keeps its name (renaming it is outward-facing); github.io is
        # blocked on the owner's network and never allowed.
        swift = ('let a = "https://github.com/HighStormPVP/AnoWine/issues"\n'
                 'let b = "https://raw.githubusercontent.com/HighStormPVP/AnoWine/main/dist/pages"\n'
                 'let c = "https://highstormpvp.github.io/AnoWine"\n'
                 'let d = "Wine bug: https://github.com/HighStormPVP/AnoWine/issues"\n'
                 'let e = "https://github.com/HighStormPVP/AnoWineFork"\n'
                 'let f = "https://github.com/someone/AnoWine"\n')
        self.assertEqual(hits({"Whisky/Views/A.swift": swift}),
                         [("Whisky/Views/A.swift", "3"), ("Whisky/Views/A.swift", "4"),
                          ("Whisky/Views/A.swift", "5"), ("Whisky/Views/A.swift", "6")])
        plist = "<key>SUFeedURL</key>\n<string>https://highstormpvp.github.io/AnoWine/appcast.xml</string>\n"
        self.assertEqual(hits({"Whisky/Info.plist": plist}), [("Whisky/Info.plist", "2")])

    def test_tests_are_not_checked(self):
        self.assertEqual(hits({"WhiskyKit/Tests/WhiskyKitTests/A.swift": 'let a = "Wine"\n'}), [])

    def test_catalog_keys_and_values(self):
        catalog = {"sourceLanguage": "en", "strings": {
            "config.winecfg": {"localizations": {"en": {"stringUnit": {"value": "Open"}}}},
            "button.ok": {"localizations": {
                "de": {"stringUnit": {"value": "Wine starten"}},
                "fr": {"variations": {"plural": {"one": {"stringUnit": {"value": "un vin wine"}}}}}}},
        }}
        found = hits({"Whisky/Localizable.xcstrings": json.dumps(catalog)})
        self.assertEqual(found, [("Whisky/Localizable.xcstrings", "key config.winecfg"),
                                 ("Whisky/Localizable.xcstrings", "button.ok [de]"),
                                 ("Whisky/Localizable.xcstrings", "button.ok [fr]")])

    def test_resources_plists_and_verbs(self):
        files = {
            "WhiskyKit/Sources/WhiskyKit/GameDatabase/Resources/GameDB.json": '{"wineVersion": "1"}\n{"a": "b"}\n',
            "Whisky/Info.plist": "<key>NSAppleEventsUsageDescription</key>\n<string>manage Wine bottles</string>\n",
            "Libraries/verbs.txt": ("===== dlls =====\nxyz  ifwinexist IfWinExist winevent fine\n"
                                    "abc  Wine thing\n"),
        }
        self.assertEqual(hits(files), [("WhiskyKit/Sources/WhiskyKit/GameDatabase/Resources/GameDB.json", "1"),
                                       ("Whisky/Info.plist", "2"), ("Libraries/verbs.txt", "3")])


if __name__ == "__main__":
    unittest.main()
