"""Tests for spawn_sites.py. Run: python3 -m unittest discover -s scripts/anowine -p 'test_*.py'"""
import contextlib
import io
import os
import sys
import tempfile
import unittest
from pathlib import Path

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
FIXTURES = Path(HERE) / "tests" / "spawn"

from spawn_sites import main  # noqa: E402

NTLM = "dlls/msv1_0/unixlib.c\tntlm_fork\tposix_spawnp"


class SpawnSiteTests(unittest.TestCase):
    def scan(self, fixture, sites_text):
        """(exit code, output) of spawn_sites.py on a fixture tree with this list."""
        with tempfile.TemporaryDirectory() as tmp:
            sites = Path(tmp) / "spawn-sites.txt"
            sites.write_text(sites_text, encoding="utf-8", newline="\n")
            out = io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
                try:
                    code = main([str(FIXTURES / fixture), "--sites", str(sites)])
                except SystemExit as stop:
                    code = stop.code
            return code, out.getvalue()

    def test_an_unlisted_site_fails(self):
        code, out = self.scan("ntlm", "")
        self.assertEqual(code, 1, out)
        self.assertIn("unlisted dlls/msv1_0/unixlib.c ntlm_fork posix_spawnp", out)

    def test_a_drops_aliases_site_without_the_helper_fails(self):
        # ntlm_cleanup calls the helper; ntlm_fork, where the spawn is, does not.
        code, out = self.scan("ntlm", f"{NTLM}\tdrops-aliases\tntlm_auth gets the environment\n")
        self.assertEqual(code, 1, out)
        self.assertIn("unhandled dlls/msv1_0/unixlib.c ntlm_fork posix_spawnp", out)
        self.assertNotIn("unlisted", out)

    def test_a_handled_site_passes(self):
        code, out = self.scan("ntlm-handled", f"{NTLM}\tdrops-aliases\tntlm_auth gets the environment\n")
        self.assertEqual(code, 0, out)
        self.assertNotIn("unlisted", out)
        self.assertNotIn("unhandled", out)

    def test_every_call_form_is_found(self):
        code, out = self.scan("forms", "")
        self.assertEqual(code, 1, out)
        for function, call in (("pipe_start_doc", "execl"), ("is_postscript_supported", "posix_spawn"),
                               ("run_spawnp", "posix_spawnp"), ("run_system", "system"),
                               ("run_popen", "popen")):
            self.assertIn(f"unlisted dlls/localspl/cups.c {function} {call}", out)
        self.assertEqual(sum(line.startswith("unlisted ") for line in out.splitlines()), 5, out)

    def test_comments_strings_and_prefixed_names_are_not_sites(self):
        code, out = self.scan("not-sites", "")
        self.assertEqual(code, 0, out)
        self.assertNotIn("unlisted", out)

    def test_tools_tests_and_headers_are_not_scanned(self):
        code, out = self.scan("skipped", "")
        self.assertEqual(code, 0, out)
        self.assertNotIn("unlisted", out)

    def test_definitions_objc_and_the_other_handlings(self):
        listed = ("dlls/crt/process.c\tsystem\tsystem\tnot-a-spawn\tthe C runtime's own system, Windows side\n"
                  "dlls/core/unix/loader.c\texec_loader\texecv\tbefore-aliases\truns before the aliases are set\n"
                  "dlls/macdrv/cocoa_app.m\topen_with_shell\tsystem\tnot-a-spawn\ta fixture\n"
                  "dlls/macdrv/cocoa_app.m\topenFile:withApp:\texeclp\tnot-a-spawn\ta fixture\n")
        code, out = self.scan("defs", "")
        self.assertEqual(code, 1, out)
        for line in listed.splitlines():
            path, function, call = line.split("\t")[:3]
            self.assertIn(f"unlisted {path} {function} {call}", out)
        # The prototype outside any function is a site of no function.
        self.assertIn("unlisted dlls/crt/process.c - system", out)
        code, out = self.scan("defs", "# path<TAB>function<TAB>call<TAB>handling<TAB>reason\n" + listed
                              + "dlls/crt/process.c\t-\tsystem\tnot-a-spawn\ta prototype\n")
        self.assertEqual(code, 0, out)

    def test_a_listed_site_that_is_gone_fails(self):
        code, out = self.scan("ntlm-handled", f"{NTLM}\tdrops-aliases\tntlm_auth\n"
                                              "dlls/gone.c\tgone\texecv\tnot-a-spawn\tremoved upstream\n")
        self.assertEqual(code, 1, out)
        self.assertIn("unused dlls/gone.c gone execv", out)

    def test_bad_input_exits_2(self):
        for text in (f"{NTLM}\tdrops-aliases\n",                          # no reason
                     f"{NTLM}\tdrops-aliases\t\n",                        # empty reason
                     f"{NTLM}\tharmless\tnot a handling\n",               # unknown handling
                     f"{NTLM}\tdrops-aliases\ta\n{NTLM}\tnot-a-spawn\tb\n"):  # listed twice
            code, out = self.scan("ntlm-handled", text)
            self.assertEqual(code, 2, f"{text!r}: {out}")
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            with tempfile.TemporaryDirectory() as tmp:
                self.assertEqual(main([str(FIXTURES / "ntlm"), "--sites", str(Path(tmp) / "missing.txt")]), 2)
                sites = Path(tmp) / "sites.txt"
                sites.write_text("")
                self.assertEqual(main([str(Path(tmp) / "no-such-tree"), "--sites", str(sites)]), 2)


if __name__ == "__main__":
    unittest.main()
