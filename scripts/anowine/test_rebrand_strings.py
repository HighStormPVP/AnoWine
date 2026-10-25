"""Tests for rebrand_strings.py. Run: python3 -m unittest discover -s scripts/anowine -p 'test_*.py'"""
import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import rebrand_strings  # noqa: E402

FIXTURE = {
    "sourceLanguage": "en",
    "strings": {
        "Welcome to Whisky": {
            "localizations": {
                "en": {"stringUnit": {"state": "translated", "value": "Welcome to Whisky"}},
                "fr": {"stringUnit": {"state": "translated", "value": "Bienvenue dans Whisky"}},
            }
        },
        "Download WhiskyWine": {
            "localizations": {
                "de": {"stringUnit": {"state": "translated", "value": "WhiskyWine herunterladen"}},
            }
        },
        "Launcher fixes (frankea/Whisky#41)": {
            "localizations": {
                "en": {"stringUnit": {"state": "translated", "value": "Launcher fixes for Whisky (frankea/Whisky#41)"}},
            }
        },
        "Open bottle": {
            "localizations": {
                "en": {"stringUnit": {"state": "translated", "value": "Open bottle"}},
            }
        },
    },
    "version": "1.0",
}


class RebrandStringsTests(unittest.TestCase):
    def rebrand(self, catalog):
        data = json.loads(json.dumps(catalog))
        changed = rebrand_strings.rebrand(data)
        return data, changed

    def value(self, data, key, lang):
        return data["strings"][key]["localizations"][lang]["stringUnit"]["value"]

    def test_english_value_is_rebranded(self):
        data, _ = self.rebrand(FIXTURE)
        self.assertEqual(self.value(data, "Welcome to Whisky", "en"), "Welcome to AnoWine")

    def test_other_language_value_is_rebranded(self):
        data, _ = self.rebrand(FIXTURE)
        self.assertEqual(self.value(data, "Welcome to Whisky", "fr"), "Bienvenue dans AnoWine")

    def test_missing_english_is_added_from_the_key(self):
        data, _ = self.rebrand(FIXTURE)
        self.assertEqual(self.value(data, "Download WhiskyWine", "en"), "Download Wine runtime")
        self.assertEqual(
            list(data["strings"]["Download WhiskyWine"]["localizations"]), ["de", "en"],
            "localizations stay alphabetical, like Xcode writes them",
        )

    def test_whiskywine_in_other_languages_becomes_wine(self):
        data, _ = self.rebrand(FIXTURE)
        self.assertEqual(self.value(data, "Download WhiskyWine", "de"), "Wine herunterladen")

    def test_upstream_repo_references_are_kept(self):
        data, _ = self.rebrand(FIXTURE)
        self.assertEqual(
            self.value(data, "Launcher fixes (frankea/Whisky#41)", "en"),
            "Launcher fixes for AnoWine (frankea/Whisky#41)",
        )

    def test_parenthetical_whiskywine_is_dropped(self):
        rewrite = rebrand_strings._rewrite
        self.assertEqual(rewrite("The Wine runtime (WhiskyWine) isn't installed.", True),
                         "The Wine runtime isn't installed.")
        self.assertEqual(rewrite("Wine 런타임(WhiskyWine)이 설치되지", False), "Wine 런타임이 설치되지")

    def test_keys_are_never_changed(self):
        data, _ = self.rebrand(FIXTURE)
        self.assertEqual(list(data["strings"]), list(FIXTURE["strings"]))

    def test_unrelated_strings_untouched(self):
        data, _ = self.rebrand(FIXTURE)
        self.assertEqual(data["strings"]["Open bottle"], FIXTURE["strings"]["Open bottle"])

    def test_second_run_changes_nothing(self):
        data, changed = self.rebrand(FIXTURE)
        self.assertTrue(changed)
        _, changed_again = self.rebrand(data)
        self.assertFalse(changed_again)

    def test_check_mode_exit_codes(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "Localizable.xcstrings")
            with open(path, "w", encoding="utf-8") as f:
                f.write(rebrand_strings.dump(FIXTURE))
            script = os.path.join(HERE, "rebrand_strings.py")
            before = subprocess.run([sys.executable, script, "--check", path])
            self.assertEqual(before.returncode, 1, "--check fails while a rewrite is pending")
            subprocess.run([sys.executable, script, path], check=True)
            after = subprocess.run([sys.executable, script, "--check", path])
            self.assertEqual(after.returncode, 0, "--check passes once rewritten")


if __name__ == "__main__":
    unittest.main()
