"""Words the 3c-4b reviews found misleading stay fixed (Plan 3c-4c Task 4).

"Ano PID" and "Ano processes ... when Ano quits" read as the app's own PID and
processes; they are the Windows programs'. The CLI's help named the original
Whisky. Run: python3 -m unittest discover -s scripts/anowine -p 'test_*.py'
"""
import json
import os
import re
import sys
import unittest
from pathlib import Path

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from swift_literals import key_of, literals  # noqa: E402

ROOT = Path(HERE).parent.parent
CATALOG = ROOT / "Whisky" / "Localizable.xcstrings"
CLI = ROOT / "WhiskyCmd" / "Main.swift"
KILL_ON_QUIT = {
    "settings.toggle.kill.on.terminate": "Terminate Windows programs when Ano closes",
    "config.cleanup.killOnQuit.help": "Controls whether Windows programs are terminated when Ano quits",
}


def strings():
    return json.loads(CATALOG.read_text(encoding="utf-8"))["strings"]


def values(key):
    """Each language's value of a catalog key."""
    entry = strings().get(key, {})
    return {lang: row["stringUnit"]["value"] for lang, row in entry.get("localizations", {}).items()}


class CatalogWordingTests(unittest.TestCase):
    def test_the_pid_beside_the_macos_pid_is_the_windows_pid(self):
        self.assertFalse("process.detail.anoPID" in strings(), "the old key is still in the catalog")
        pid = values("process.detail.windowsPID")
        self.assertEqual(set(pid), set(values("process.detail.macosPID")))
        self.assertEqual(pid.get("en"), "Windows PID")
        self.assertEqual(pid.get("en-GB"), "Windows PID")
        for lang, value in pid.items():
            self.assertIn("Windows", value, lang)
            self.assertNotIn("Ano", value, lang)

    def test_kill_on_quit_names_the_windows_programs(self):
        for key, english in KILL_ON_QUIT.items():
            texts = values(key)
            self.assertEqual(texts.get("en"), english, key)
            self.assertEqual(texts.get("en-GB"), english, key)
            self.assertGreater(len(texts), 2, key)
            for lang, value in texts.items():
                # Ano is only the app that quits; the programs are Windows programs.
                self.assertIn("Windows", value, f"{key} {lang}")
                self.assertEqual(value.count("Ano"), 1, f"{key} {lang}: {value}")


class CommandLineWordingTests(unittest.TestCase):
    def setUp(self):
        self.source = CLI.read_text(encoding="utf-8")
        self.texts = [key_of(lit) for lit in literals(self.source)]

    def test_no_cli_text_names_whisky(self):
        whisky = [text for text in self.texts if "whisky" in text.lower()]
        self.assertEqual(whisky, [])

    def test_the_run_help_shows_ano_run(self):
        self.assertTrue(any("ano run MyBottle app.exe -- --follow" in text for text in self.texts))

    def test_the_usage_line_names_ano(self):
        # ArgumentParser names a command after its type unless commandName says
        # otherwise, so the root `struct Whisky` would print "USAGE: whisky ...".
        root = re.search(r"struct Whisky: AsyncParsableCommand \{(.*?)subcommands:", self.source, re.S)
        self.assertIsNotNone(root)
        self.assertRegex(root.group(1), r'commandName:\s*"ano"')


if __name__ == "__main__":
    unittest.main()
