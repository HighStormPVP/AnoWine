"""Tests for make_ano_tricks.py. Run: python3 -m unittest discover -s scripts/anowine -p 'test_*.py'"""
import os
import sys
import unittest
from pathlib import Path

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from make_ano_tricks import (  # noqa: E402
    SEPARATOR, drop_verbs, load_tricks_rules, rename, replace_in_function, replace_once, stub_function,
    wine_urls_left)

KEPT = """w_metadata vcrun2022 dlls \\
    title="Visual C++"

load_vcrun2022()
{
    w_download "https://example.com/vc.exe"
}
"""
NINE = """# $1 - archive name
helper_galliumnine()
{
    w_try mv x y
}

w_metadata galliumnine02 dlls \\
    homepage="https://github.com/iXit/wine-nine-standalone"

load_galliumnine02()
{
    helper_galliumnine "x"
}

w_metadata galliumnine dlls \\
    title="Gallium Nine"

load_galliumnine()
{
    w_call galliumnine02
}
"""


def script(*chunks):
    return "#!/bin/sh\n" + "".join(SEPARATOR + "\n" + chunk + "\n" for chunk in chunks)


class DropVerbTests(unittest.TestCase):
    def test_drops_the_chunk_of_a_verb_and_its_helper(self):
        out = drop_verbs(script(KEPT, NINE), {"galliumnine", "galliumnine02"}, {"galliumnine"})
        self.assertIn("load_vcrun2022()", out)
        self.assertNotIn("galliumnine", out)
        self.assertNotIn("wine-nine-standalone", out)

    def test_refuses_a_chunk_that_also_holds_a_kept_verb(self):
        with self.assertRaisesRegex(ValueError, "vcrun2022"):
            drop_verbs(script(KEPT + "\n" + NINE), {"galliumnine", "galliumnine02"}, {"galliumnine"})

    def test_refuses_a_verb_that_is_not_there(self):
        with self.assertRaisesRegex(ValueError, "ie8"):
            drop_verbs(script(KEPT, NINE), {"galliumnine", "galliumnine02", "ie8"}, {"galliumnine"})

    def test_refuses_a_kept_caller_of_a_dropped_verb(self):
        caller = KEPT.replace('w_download "https://example.com/vc.exe"', "w_call galliumnine")
        with self.assertRaisesRegex(ValueError, "w_call galliumnine"):
            drop_verbs(script(caller, NINE), {"galliumnine", "galliumnine02"}, {"galliumnine"})


class EditTests(unittest.TestCase):
    def test_stub_replaces_the_whole_body(self):
        text = "a()\n{\n    x\n}\n\nwinetricks_selfupdate()\n{\n    curl x\n    if y; then\n        z\n    fi\n}\n\nb()\n{\n}\n"
        out = stub_function(text, "winetricks_selfupdate", "    return\n")
        self.assertEqual(out, "a()\n{\n    x\n}\n\nwinetricks_selfupdate()\n{\n    return\n}\n\nb()\n{\n}\n")

    def test_stub_handles_a_brace_on_the_same_line(self):
        text = "winetricks_dl_warning() {\n    curl https://ipinfo.io/ip\n}\n"
        self.assertEqual(stub_function(text, "winetricks_dl_warning", "    return\n"),
                         "winetricks_dl_warning()\n{\n    return\n}\n")

    def test_stub_refuses_a_missing_function(self):
        with self.assertRaisesRegex(ValueError, "winetricks_stats_report"):
            stub_function("a()\n{\n}\n", "winetricks_stats_report", "    return\n")

    def test_replace_in_function_only_touches_that_function(self):
        text = "load_vcrun2019()\n{\n    x -F 'a'\n}\n\nload_vcrun2022()\n{\n    x -F 'a'\n}\n"
        out = replace_in_function(text, "load_vcrun2022", "    x -F 'a'\n", "    x -F 'a_x86'\n")
        self.assertEqual(out, "load_vcrun2019()\n{\n    x -F 'a'\n}\n\nload_vcrun2022()\n{\n    x -F 'a_x86'\n}\n")
        with self.assertRaises(ValueError):
            replace_in_function(text, "load_vcrun2022", "    y\n", "    z\n")

    def test_replace_once_refuses_none_or_two(self):
        self.assertEqual(replace_once("a b c", "b", "x"), "a x c")
        with self.assertRaises(ValueError):
            replace_once("a c", "b", "x")
        with self.assertRaises(ValueError):
            replace_once("b b", "b", "x")


class RenameTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rules = load_tricks_rules()

    def test_programs_variables_and_functions(self):
        cases = {
            'WINEPREFIX="$p" winetricks -q vcrun2022': 'ANOPREFIX="$p" ano-tricks -q vcrun2022',
            '"${WINEPREFIX}/winetricks.log"': '"${ANOPREFIX}/ano-tricks.log"',
            'W_CACHE="${W_CACHE:-${XDG_CACHE_HOME}/winetricks}"': 'W_CACHE="${W_CACHE:-${XDG_CACHE_HOME}/ano-tricks}"',
            "winetricks_init": "anotricks_init",
            'if ! test "${WINETRICKS_LIB}"; then': 'if ! test "${ANOTRICKS_LIB}"; then',
            '"${WINE}" wineboot': '"${ANO}" ano-boot',
            'WINESERVER="$(command -v wineserver)"': 'ANOSERVER="$(command -v ano-server)"',
            "HKEY_CURRENT_USER\\Software\\Wine\\DllOverrides": "HKEY_CURRENT_USER\\Software\\Ano\\DllOverrides",
            "sed -e 's/wine-//' -e 's/-rc.*//'": "sed -e 's/ano-//' -e 's/-rc.*//'",
            'w_warn "Winetricks failed"': 'w_warn "Ano-tricks failed"',
        }
        for old, new in cases.items():
            self.assertEqual(rename(old, self.rules), new, old)

    def test_autohotkey_and_windows_names_stay(self):
        for text in ("ifwinexist, Fatal error, Failed", "ifWinExist, Verification Utility",
                     "api-ms-win-rtcore-ntuser-winevent-l1-1-0 \\"):
            self.assertEqual(rename(text, self.rules), text)

    def test_upstream_links_become_the_repo(self):
        self.assertEqual(rename("# https://github.com/Winetricks/winetricks/issues/2030", self.rules),
                         "# https://github.com/HighStormPVP/AnoWine")
        self.assertEqual(rename("# https://bugs.winehq.org/show_bug.cgi?id=21009", self.rules),
                         "# https://github.com/HighStormPVP/AnoWine/issues")


class UrlTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rules = load_tricks_rules()

    def test_a_wine_url_on_another_host_is_reported(self):
        text = ('w_download "https://github.com/otya128/winevdm/releases/download/v0.9.0/otvdm.zip"\n'
                "# https://code.google.com/p/winezeug/issues/detail?id=78\n")
        self.assertEqual(wine_urls_left(text, self.rules),
                         ["https://github.com/otya128/winevdm/releases/download/v0.9.0/otvdm.zip",
                          "https://code.google.com/p/winezeug/issues/detail?id=78"])

    def test_mapped_hosts_and_plain_urls_are_not_reported(self):
        text = ("# https://bugs.winehq.org/show_bug.cgi?id=1\n# https://appdb.winehq.org/x\n"
                "# https://github.com/Winetricks/winetricks/issues/1\nw_download https://example.com/a.exe\n")
        self.assertEqual(wine_urls_left(text, self.rules), [])


class CommittedFileTests(unittest.TestCase):
    def test_libraries_ano_tricks_exists(self):
        path = Path(HERE).parent.parent / "Libraries" / "ano-tricks"
        self.assertTrue(path.is_file(), f"{path} is missing: run scripts/anowine/make_ano_tricks.py")

    def committed(self):
        return (Path(HERE).parent.parent / "Libraries" / "ano-tricks").read_text(encoding="utf-8")

    def test_vcrun2022_copies_msvcp140_through_the_helper(self):
        # In the pinned VC++ 2022 redistributables the file is msvcp140.dll_x86 (a10)
        # and msvcp140.dll_amd64 (a12); upstream's -F 'msvcp140.dll' extracts nothing.
        # w_ano_msvcp140 takes any msvcp140.dll* and keeps the builtin if there is none
        # (test-ano-tricks.sh runs it both ways).
        text = self.committed()
        body = text[text.index("load_vcrun2022()"):]
        body = body[:body.index("\n}\n")]
        self.assertIn('w_ano_msvcp140 "${W_TMP}/win32/a10" "${W_TMP}/win32" "${W_SYSTEM32_DLLS}"', body)
        self.assertIn('w_ano_msvcp140 "${W_TMP}/win64/a12" "${W_TMP}/win64" "${W_SYSTEM64_DLLS}"', body)
        self.assertNotIn("-F 'msvcp140.dll'", body)

    def test_the_64_bit_loader_keeps_its_name(self):
        # Renamed, upstream's sed 's/^wine/wine64/' turns ano-loader into ano64-loader.
        self.assertNotIn("sed 's/^ano/ano64/'", self.committed())

    def test_it_says_it_is_a_modified_copy(self):
        # LGPL 2.1 section 2(b): prominent notice of the change and its date.
        head = self.committed()[:4000]
        self.assertIn("a modified copy of Winetricks 20260125", head)
        self.assertIn("2026-11-21", head)
        self.assertIn("Copyright (C) 2007-2014 Dan Kegel", head)


if __name__ == "__main__":
    unittest.main()
