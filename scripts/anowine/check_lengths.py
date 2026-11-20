#!/usr/bin/env python3
"""Find renamed string literals next to their old length (Plan 3c-1).

Usage: check_lengths.py TREE [--known FILE]

wine -> ano makes a literal one character shorter for each occurrence. Code
that spells a literal's length as a number (wcsncmp(p, L"WINEDEBUG=", 10))
then compares too much, skips too far or reads past the literal. In C-family
files outside tests, a string literal that says ano, Ano or ANO (not ano-: a
program name keeps its length) is reported when its old length, or that plus
its NUL, appears as a number on the same line or the next; debug output is
left out. The tree is the renamed one, after patches/rename, which fix the
real sites. --known lists the sites that are not lengths
(path<TAB>literal<TAB>why). Exit 1 for an unknown site, or a known one that no
longer occurs.
"""
import argparse
import os
import re
import sys
from pathlib import Path

SUFFIXES = (".c", ".h", ".m", ".y", ".l")
LITERAL = re.compile(r'L?"((?:\\.|[^"\\\n])*)"')
NUMBER = re.compile(r"(?<![\w.])(\d+)(?![\w.])")
RENAMED = re.compile(r"(?:ano|Ano|ANO)(?!-)")
DEBUG = re.compile(r"TRACE|WARN|FIXME|ERR\(|printf|MESSAGE|debugstr")
ESCAPE = re.compile(r"\\(?:x[0-9A-Fa-f]+|[0-7]{1,3}|.)")


def stale_lengths(tree) -> list:
    """[(relative path, line number, literal as written, old length)]."""
    tree = Path(tree)
    hits = []
    for dirpath, dirnames, filenames in os.walk(tree):
        dirnames[:] = sorted(d for d in dirnames if d not in ("tests", ".git"))
        for name in sorted(filenames):
            if not name.endswith(SUFFIXES):
                continue
            path = Path(dirpath) / name
            rel = path.relative_to(tree).as_posix()
            lines = path.read_text(encoding="utf-8", errors="replace").split("\n")
            for i, line in enumerate(lines):
                if not RENAMED.search(line) or DEBUG.search(line):
                    continue
                following = lines[i + 1] if i + 1 < len(lines) else ""
                for match in LITERAL.finditer(line):
                    shortened = len(RENAMED.findall(match.group(1)))
                    if not shortened:
                        continue
                    old = len(ESCAPE.sub("x", match.group(1))) + shortened
                    rest = f"{line[:match.start()]} {line[match.end():]} {following}"
                    numbers = {int(n) for n in NUMBER.findall(rest)}
                    if old in numbers or old + 1 in numbers:
                        hits.append((rel, i + 1, match.group(0), old))
    return hits


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Find renamed literals next to their old length.")
    parser.add_argument("tree", type=Path)
    parser.add_argument("--known", type=Path)
    args = parser.parse_args(argv)
    known = {}
    if args.known:
        for number, line in enumerate(args.known.read_text(encoding="utf-8").splitlines(), 1):
            if not line.strip() or line.startswith("#"):
                continue
            fields = line.split("\t")
            if len(fields) != 3 or not all(fields):
                print(f"check_lengths.py: {args.known} line {number}: expected path<TAB>literal<TAB>why",
                      file=sys.stderr)
                return 1
            known[(fields[0], fields[1])] = fields[2]
    hits = stale_lengths(args.tree)
    seen = {(rel, literal) for rel, _, literal, _ in hits}
    problems = [f"stale length\t{rel}:{line}\t{literal}\t(was {old} characters)"
                for rel, line, literal, old in hits if (rel, literal) not in known]
    problems += [f"unused known site\t{rel}\t{literal}" for rel, literal in known if (rel, literal) not in seen]
    for problem in problems:
        print(problem)
    known_hits = sum(1 for rel, _, literal, _ in hits if (rel, literal) in known)
    print(f"check_lengths: {len(hits)} site(s), {known_hits} known not to be lengths")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
