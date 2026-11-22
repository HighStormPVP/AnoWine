"""Tests for rename_app_text.py. Run: python3 -m unittest discover -s scripts/anowine -p 'test_*.py'"""
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from check_catalog_keys import scan as check_keys  # noqa: E402
from rebrand_strings import dump  # noqa: E402
from rename_app_text import RenameError, key_renames, rename_key, rename_text, run  # noqa: E402


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


class TextRuleTests(unittest.TestCase):
    def test_the_rule(self):
        cases = {
            "Open Wine Configuration": "Open Ano Configuration",
            "Downloading Wine runtime": "Downloading Ano runtime",
            "Install Winetricks verbs": "Install Ano-tricks verbs",
            "The winetricks tool": "The ano-tricks tool",
            "Restart wineserver, then winecfg": "Restart ano-server, then ano-cfg",
            "Enable verbose Wine logging (WINEDEBUG)": "Enable verbose Ano logging (ANODEBUG)",
            "games fall back to WineD3D": "games fall back to AnoD3D",
            "Update WhiskyWine": "Update Ano runtime",
        }
        for old, new in cases.items():
            self.assertEqual(rename_text(old, "en"), new)
        self.assertEqual(rename_text("WhiskyWine aktualisieren", "de"), "Ano aktualisieren")
        self.assertEqual(rename_text("Winetrickit...", "fi"), "Ano-trickit...")

    def test_rewordings_are_logged(self):
        changes = []
        self.assertEqual(rename_text("This is a Wine system process.", "en", changes, "k"),
                         "This is an Ano system process.")
        self.assertEqual(rename_text("Rosetta allows x86 code, like Wine, to run on your Mac.", "en-GB", changes, "r"),
                         "Rosetta allows x86 code, like Ano's engine, to run on your Mac.")
        self.assertEqual(rename_text("Ano puts Wine's d3d11.dll here; it uses Wine's own Direct3D.", "en"),
                         "Ano puts the engine's d3d11.dll here; it uses the engine's own Direct3D.")
        self.assertEqual(rename_text("Ano cannot find Wine's own Direct3D for this engine.", "en"),
                         "Ano cannot find this engine's own Direct3D.")
        self.assertEqual([(c.where, c.lang, c.after) for c in changes],
                         [("k", "en", "This is an Ano system process."),
                          ("r", "en-GB", "Rosetta allows x86 code, like Ano's engine, to run on your Mac.")])

    def test_grammar_in_other_languages(self):
        cases = [
            ("fr", "Ouvrir la configuration de Wine", "Ouvrir la configuration d'Ano"),
            ("fr", "La version que Wine signale", "La version qu'Ano signale"),
            ("fr", "fermeture de Ano", "fermeture de Ano"),  # not this task's: no Wine in it
            ("cs", "PID ve Wine", "PID v Ano"),
            ("fi", "Wineä ei ehkä ole alustettu. Winen prosessi.", "Anoa ei ehkä ole alustettu. Anon prosessi."),
            ("tr", "Wine'ın bildirdiği; Wine'nin yeni versiyonu", "Ano'nun bildirdiği; Ano'nun yeni versiyonu"),
            ("ko", "Wine이 보고하는 Wine과 같은 Wine를", "Ano가 보고하는 Ano와 같은 Ano를"),
            ("pl", "logowanie WINE (WINEDEBUG)", "logowanie Ano (ANODEBUG)"),
            ("de", "Das Wine-Präfix und Wines Mac-Treiber", "Das Ano-Präfix und Anos Mac-Treiber"),
        ]
        for lang, old, new in cases:
            self.assertEqual(rename_text(old, lang), new, lang)

    def test_english_rewordings_stay_in_english(self):
        self.assertEqual(rename_text("Rosetta, kuten Wine, mahdollistaa", "fi"), "Rosetta, kuten Ano, mahdollistaa")
        self.assertEqual(rename_text("PID de Wine", "es"), "PID de Ano")


class KeyTests(unittest.TestCase):
    def test_dotted_keys_take_the_code_form(self):
        cases = {
            "setup.whiskywine.download": "setup.anoRuntime.download",
            "winetricks.filter.installedCount %lld": "anoTricks.filter.installedCount %lld",
            "troubleshooting.fixName.installWinetricksVerb": "troubleshooting.fixName.installAnoTricksVerb",
            "troubleshooting.fixName.restartWineserver": "troubleshooting.fixName.restartAnoServer",
            "troubleshooting.resume.change.wineserverStarted": "troubleshooting.resume.change.anoServerStarted",
            "config.winecfg": "config.anoCfg",
            "config.graphics.backend.wined3d.summary": "config.graphics.backend.anod3d.summary",
            "launcher.config.rockstarWineD3D.toggle": "launcher.config.rockstarAnoD3D.toggle",
            "diagnostics.wineDebug.crash": "diagnostics.anoDebug.crash",
            "audio.test.wine": "audio.test.ano",
            "wine.clearShaderCaches": "ano.clearShaderCaches",
        }
        for old, new in cases.items():
            self.assertEqual(rename_key(old), new)

    def test_text_keys_take_the_text_rule(self):
        self.assertEqual(rename_key("Running winetricks for %@"), "Running ano-tricks for %@")
        self.assertEqual(rename_key("Analyze Wine crash output"), "Analyze Ano crash output")

    def test_a_new_key_that_is_already_a_key_fails(self):
        with self.assertRaises(RenameError):
            key_renames({"audio.test.wine": {}, "audio.test.ano": {}})


SWIFT_VIEW = '''// winetricks.title in a comment stays
struct V: View {
    var body: some View {
        Text("winetricks.title")
        Text("Running winetricks for \\(definition.displayName)")
        let label = "Wine"
        let key = "winetricks.category.\\(category.rawValue)"
        Text(NSLocalizedString(key, comment: ""))
        Toggle("Map", isOn: $on)
            .help("""
            Sets it in Wine's Mac \\
            driver registry so keys register.
            """)
        Text("troubleshooting.check.winetricks.missing \\(count) \\(names)")
    }
}
'''
SWIFT_TEST = '''XCTAssertEqual(summary, "troubleshooting.check.winetricks.missing 2 d3dx9, dotnet48")
XCTAssertEqual(stem, "winetricks.title")
'''


class RunTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        strings = {
            "button.ok": {"localizations": {"en": unit("OK")}},
            "Map": {},
            "winetricks.title": {"localizations": {"en": unit("Run Winetricks Command"),
                                                   "en-GB": unit("Run Winetricks Command"),
                                                   "fr": unit("Exécuter une commande Winetricks")}},
            "Running winetricks for %@": {"localizations": {"de": unit("Winetricks läuft für %@")}},
            "winetricks.category.apps": {"localizations": {"en": unit("Apps")}},
            "Sets it in Wine's Mac driver registry so keys register.": {},
            "troubleshooting.check.winetricks.missing %lld %@": {"localizations": {
                "en": unit("%1$lld missing verb(s): %2$@"), "pl": unit("Brak %1$lld (Winetricks): %2$@")}},
            "config.title.wine": {"localizations": {"en": unit("Wine"), "fr": unit("Wine")}},
            "last": {"localizations": {"en": unit("The Wine prefix")}},
        }
        self.catalog = self.root / "Whisky/Localizable.xcstrings"
        self.write("Whisky/Localizable.xcstrings", dump({"sourceLanguage": "en", "strings": strings, "version": "1.0"}))
        self.write("Whisky/Views/V.swift", SWIFT_VIEW)
        self.write("WhiskyKit/Tests/WhiskyKitTests/T.swift", SWIFT_TEST)

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, rel, text):
        (self.root / rel).parent.mkdir(parents=True, exist_ok=True)
        (self.root / rel).write_bytes(text.encode("utf-8"))

    def read(self, rel):
        return (self.root / rel).read_bytes().decode("utf-8")

    def run_script(self, **flags):
        out = io.StringIO()
        run(self.root, flags.get("keys", True), flags.get("values", True), flags.get("dry_run", False), out)
        return out.getvalue()

    def test_keys_values_and_swift_change_together(self):
        self.run_script()
        raw = self.catalog.read_bytes()
        self.assertNotIn(b"\r\n", raw)
        catalog = json.loads(raw.decode("utf-8"))
        self.assertEqual(raw.decode("utf-8"), dump(catalog))
        self.assertEqual(list(catalog["strings"]), [
            "button.ok", "Map", "anoTricks.title", "Running ano-tricks for %@", "anoTricks.category.apps",
            "Sets it in Ano's Mac driver registry so keys register.",
            "troubleshooting.check.anoTricks.missing %lld %@", "config.title.ano", "last"])
        title = catalog["strings"]["anoTricks.title"]["localizations"]
        self.assertEqual(title["en"]["stringUnit"]["value"], "Run Ano-tricks Command")
        self.assertEqual(title["fr"]["stringUnit"]["value"], "Exécuter une commande Ano-tricks")
        self.assertEqual(catalog["strings"]["last"]["localizations"]["en"]["stringUnit"]["value"], "The Ano prefix")
        self.assertNotIn("wine", raw.decode("utf-8").lower())

        view = self.read("Whisky/Views/V.swift")
        self.assertIn('// winetricks.title in a comment stays', view)
        self.assertIn('Text("anoTricks.title")', view)
        self.assertIn('Text("Running ano-tricks for \\(definition.displayName)")', view)
        self.assertIn('let label = "Wine"', view)  # not a key: Task 3's
        self.assertIn('"anoTricks.category.\\(category.rawValue)"', view)
        self.assertIn("Sets it in Ano's Mac \\\n", view)
        self.assertIn('Text("troubleshooting.check.anoTricks.missing \\(count) \\(names)")', view)
        tests = self.read("WhiskyKit/Tests/WhiskyKitTests/T.swift")
        self.assertIn('"troubleshooting.check.anoTricks.missing 2 d3dx9, dotnet48"', tests)
        self.assertIn('"anoTricks.title"', tests)
        self.assertEqual(list(check_keys(self.root)), [])

    def test_running_again_changes_nothing(self):
        self.run_script()
        before = (self.catalog.read_bytes(), self.read("Whisky/Views/V.swift"))
        self.run_script()
        self.assertEqual((self.catalog.read_bytes(), self.read("Whisky/Views/V.swift")), before)

    def test_dry_run_writes_nothing(self):
        before = self.catalog.read_bytes()
        out = self.run_script(dry_run=True)
        self.assertEqual(self.catalog.read_bytes(), before)
        self.assertIn("key: 'winetricks.title' -> 'anoTricks.title'", out)

    def test_half_a_rename_is_what_the_key_check_catches(self):
        self.run_script(keys=True, values=False)
        self.write("Whisky/Views/V.swift", SWIFT_VIEW)  # Swift back to the old keys
        found = sorted((m.rule, m.key) for m in check_keys(self.root))
        self.assertIn(("call", "winetricks.title"), found)
        self.assertIn(("prefix", "winetricks.category.\\(...)"), found)

    def test_a_changed_placeholder_fails(self):
        import rename_app_text
        saved = rename_app_text.REWORDINGS
        rename_app_text.REWORDINGS = (rename_app_text._r(None, r"%@", "", "breaks it"),)
        try:
            with self.assertRaises(RenameError):
                self.run_script(keys=False)
        finally:
            rename_app_text.REWORDINGS = saved


if __name__ == "__main__":
    unittest.main()
