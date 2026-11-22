"""Tests for check_catalog_keys.py and swift_literals.py.

Run: python3 -m unittest discover -s scripts/anowine -p 'test_*.py'
"""
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from check_catalog_keys import scan  # noqa: E402
from swift_literals import INTERP, key_of, literals, normalize_key  # noqa: E402

KEYS = ["winetricks.title", "winetricks.category.apps", "status.count %lld", "Running winetricks for %@",
        "pin.error.duplicate.%@", "Hello", "Sets it in Wine's Mac driver registry so keys register.",
        "audio.probe.failed %@ %@", "Rate: 100%%"]


def tree(tmp, swift, keys=KEYS, rel="Whisky/Views/A.swift"):
    root = Path(tmp)
    catalog = {"sourceLanguage": "en", "strings": {key: {} for key in keys}, "version": "1.0"}
    (root / "Whisky").mkdir(parents=True, exist_ok=True)
    (root / "Whisky/Localizable.xcstrings").write_text(json.dumps(catalog), encoding="utf-8")
    (root / rel).parent.mkdir(parents=True, exist_ok=True)
    (root / rel).write_text(swift, encoding="utf-8")
    return root


def misses(swift, keys=KEYS, rel="Whisky/Views/A.swift"):
    with tempfile.TemporaryDirectory() as tmp:
        return [(m.line, m.rule, m.key) for m in scan(tree(tmp, swift, keys, rel))]


class SwiftLiteralTests(unittest.TestCase):
    def keys(self, swift):
        return [key_of(lit) for lit in literals(swift)]

    def test_escapes_and_interpolations(self):
        self.assertEqual(self.keys(r'let a = "say \"hi\" \(name) \\ \u{41}"'), [f'say "hi" {INTERP} \\ A'])

    def test_a_string_inside_an_interpolation_is_code(self):
        swift = 'Text("count \\(f("x)", y)) done")\nlet b = "next"'
        self.assertEqual(self.keys(swift), [f"count {INTERP} done", "next"])

    def test_comments_are_not_literals(self):
        swift = '// "not this"\n/* "nor /* nested */ this" */\nlet a = "this"'
        self.assertEqual(self.keys(swift), ["this"])

    def test_multiline_literal_with_continuations(self):
        swift = ('    .help("""\n'
                 '        Sets it in Wine\'s Mac \\\n'
                 '        driver registry \\\n'
                 '        so keys register.\n'
                 '        """)\n')
        self.assertEqual(self.keys(swift), ["Sets it in Wine's Mac driver registry so keys register."])

    def test_raw_string(self):
        self.assertEqual(self.keys(r'let a = #"C:\path \#(x)"#'), [f"C:\\path {INTERP}"])

    def test_normalize_key(self):
        self.assertEqual(normalize_key("a %1$@ b %lld c %%"), f"a {INTERP} b {INTERP} c %")


class CheckTests(unittest.TestCase):
    def test_keys_in_the_catalog_pass(self):
        swift = ('let a = String(localized: "winetricks.title")\n'
                 'let b = String(\n    localized: "status.count \\(n)"\n)\n'
                 'Text("Running winetricks for \\(name)")\n'
                 'Text("pin.error.duplicate.\\(name)")\n'
                 'Button("Hello") {}\n'
                 'let c = NSLocalizedString("winetricks.title", comment: "")\n'
                 'let d = String(localized: "audio.probe.failed \\(a) \\(b)")\n'
                 'Text("Rate: 100%")\n'
                 '.help("""\n    Sets it in Wine\'s Mac \\\n    driver registry so keys register.\n    """)\n')
        self.assertEqual(misses(swift), [])

    def test_a_key_missing_from_the_catalog_fails(self):
        swift = 'let a = String(localized: "anoTricks.title")\nText("Running ano-tricks for \\(name)")\n'
        self.assertEqual(misses(swift), [(1, "call", "anoTricks.title"),
                                         (2, "call", "Running ano-tricks for \\(...)")])

    def test_a_dotted_key_anywhere_is_checked(self):
        swift = ('case .title: return "winetricks.title"\n'
                 'case .other: return "winetricks.titel"\n'
                 'let exe = "winetricks.exe"\n'
                 '.accessibilityIdentifier("winetricks.row")\n'
                 'let id = "elsewhere.thing"\n')
        self.assertEqual(misses(swift), [(2, "identifier", "winetricks.titel")])

    def test_a_key_built_at_run_time_needs_a_key_with_its_head(self):
        self.assertEqual(misses('let key = "winetricks.category.\\(category)"\n'), [])
        self.assertEqual(misses('let key = "winetricks.kind.\\(category)"\n'),
                         [(1, "prefix", "winetricks.kind.\\(...)")])
        self.assertEqual(misses('let key = "gone.kind.\\(category)"\nlet q = "com.example.\\(name)"\n'),
                         [(1, "prefix", "gone.kind.\\(...)")])

    def test_a_namespace_the_catalog_no_longer_has_is_still_checked(self):
        renamed = [key.replace("winetricks", "anoTricks") for key in KEYS]
        swift = ('Text("winetricks.title")\n'
                 'case .search: return "winetricks.search.prompt"\n'
                 'Image(systemName: "speaker.wave.2")\n'
                 'let symbol = "checkmark.circle.fill"\n')
        self.assertEqual(misses(swift, renamed), [(1, "call", "winetricks.title"),
                                                  (2, "identifier", "winetricks.search.prompt")])

    def test_text_shown_as_it_is_is_not_a_key(self):
        swift = 'Text("•")\nText("\\(a) / \\(b)")\nText("1920")\nText("Content")\nText("\\(rate) Hz")\n'
        self.assertEqual(misses(swift), [])

    def test_comments_and_tests_are_not_checked(self):
        self.assertEqual(misses('// Text("missing.key")\n'), [])
        self.assertEqual(misses('Text("missing.key")\n', rel="WhiskyKit/Tests/WhiskyKitTests/A.swift"), [])

    def test_whiskykit_lookups_are_checked(self):
        self.assertEqual(misses('let a = String(localized: "winetricks.nope")\n',
                                rel="WhiskyKit/Sources/WhiskyKit/A.swift"),
                         [(1, "call", "winetricks.nope")])


if __name__ == "__main__":
    unittest.main()
