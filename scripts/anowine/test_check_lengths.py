"""Tests for check_lengths.py. Run: python3 -m unittest discover -s scripts/anowine -p 'test_*.py'"""
import contextlib
import io
import os
import sys
import tempfile
import unittest
from pathlib import Path

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from check_lengths import main, stale_lengths  # noqa: E402


def tree(tmp, files):
    root = Path(tmp) / "src"
    for rel, text in files.items():
        (root / rel).parent.mkdir(parents=True, exist_ok=True)
        (root / rel).write_text(text, encoding="utf-8")
    return root


class StaleLengthTests(unittest.TestCase):
    def hits(self, files):
        with tempfile.TemporaryDirectory() as tmp:
            return [(rel, literal) for rel, _, literal, _ in stale_lengths(tree(tmp, files))]

    def test_old_length_next_to_a_renamed_literal(self):
        # "WINEDEBUG=" was 10 characters; renamed it is 9.
        self.assertEqual(self.hits({"dlls/k/debug.c": 'if (!wcsncmp( p, L"ANODEBUG=", 10 ))\n'}),
                         [("dlls/k/debug.c", 'L"ANODEBUG="')])
        # With its NUL: "WINEUSERLOCALE" 14 + 1.
        self.assertEqual(self.hits({"a.c": 'n = sizeof(x) ? 15 : 0; q("ANOUSERLOCALE");\n'}),
                         [("a.c", '"ANOUSERLOCALE"')])
        # The number may be on the next line.
        self.assertEqual(self.hits({"a.c": 'if (!strncmp(spec, "ano:",\n            5))\n'}),
                         [("a.c", '"ano:"')])

    def test_current_length_is_fine(self):
        self.assertEqual(self.hits({"a.c": 'if (!wcsncmp( p, L"ANODEBUG=", 9 )) p += 9;\n'}), [])

    def test_program_names_keep_their_length(self):
        # wineboot -> ano-boot: same length, nothing to fix.
        self.assertEqual(self.hits({"a.c": 'run("ano-boot.exe", 12);\n'}), [])

    def test_debug_output_and_tests_are_skipped(self):
        self.assertEqual(self.hits({"a.c": 'TRACE("ANO_ %d\\n", 5);\n',
                                    "dlls/x/tests/t.c": 'ok(!strncmp(s, "ANO_", 5), "x");\n'}), [])

    def test_known_sites(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = tree(tmp, {"svc.c": 'static WCHAR n[ARRAY_SIZE(L"Anodevice") + 10];\n'})
            known = Path(tmp) / "known.txt"
            known.write_text("")
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                self.assertEqual(main([str(root), "--known", str(known)]), 1)
            self.assertIn('stale length\tsvc.c:1\tL"Anodevice"', out.getvalue())
            known.write_text('# path<TAB>literal<TAB>why\nsvc.c\tL"Anodevice"\t10 is the width of a number\n')
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(main([str(root), "--known", str(known)]), 0)
            # A known site that no longer occurs is an error too.
            known.write_text(known.read_text() + 'gone.c\t"ANO_"\tremoved\n')
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                self.assertEqual(main([str(root), "--known", str(known)]), 1)
            self.assertIn('unused known site\tgone.c\t"ANO_"', out.getvalue())


if __name__ == "__main__":
    unittest.main()
