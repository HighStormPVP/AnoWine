#!/usr/bin/env python3
"""Every place the renamed engine starts a program, listed and handled (Plan 3c-5).

Usage: spawn_sites.py SRC --sites FILE

Apple's D3DMetal reads WINED3DMETAL and WINEESYNC, so each engine process sets
them from ANOD3DMETAL and ANOESYNC in its own environment (patches/rename/0005).
A program the engine starts must not get them: every call that starts one with
the live environment drops them first.

A site is a call to execl, execle, execlp, execv, execve, execvp, execvpe,
fexecve, posix_spawn, posix_spawnp, system or popen in a .c or .m file under
SRC (tools/ and */tests/* left out), found after comments, strings and
character literals are blanked; _execv( or my_system( is another name. Its key
is (path relative to SRC, enclosing function, call), not a line number, so it
survives upstream line changes; a call outside any function has the function
"-". FILE lists each site once: path<TAB>function<TAB>call<TAB>handling<TAB>reason,
where handling is
  drops-aliases   the enclosing function's body calls ano_env_without_aliases(
                  or ano_env_unset_aliases( (checked here);
  before-aliases  the site runs before ano_env_set_aliases;
  not-a-spawn     a definition, or Windows-side code such as msvcrt's own system.
Exit 0 when every site is listed and handled. Exit 1 otherwise, printing
"unlisted <path> <function> <call>", "unhandled <path> <function> <call>" or,
for a listed site that no longer occurs, "unused <path> <function> <call>".
Exit 2 on bad input.
"""
import argparse
import os
import re
import sys
from pathlib import Path

CALLS = ("execl", "execle", "execlp", "execv", "execve", "execvp", "execvpe", "fexecve",
         "posix_spawn", "posix_spawnp", "system", "popen")
CALL = re.compile(r"(?<![A-Za-z0-9_$])(" + "|".join(CALLS) + r")\s*\(")
HELPER = re.compile(r"(?<![A-Za-z0-9_$])ano_env_(?:without|unset)_aliases\s*\(")
HANDLINGS = ("drops-aliases", "before-aliases", "not-a-spawn")
SUFFIXES = (".c", ".m")
# Comments, string literals and character literals, left to right, so a quote
# inside a comment or a character literal opens no string.
CODE_SPAN = re.compile(r"""//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'""", re.S)
# A preprocessor directive with its continuation lines.
DIRECTIVE = re.compile(r"^[ \t]*#(?:[^\n]*\\\n)*[^\n]*", re.M)
IDENTIFIER = re.compile(r"[A-Za-z_][A-Za-z0-9_]*$")
OBJC_METHOD = re.compile(r"^[ \t]*[-+][ \t]*\(", re.M)


def blank(match) -> str:
    """The match with every character but newlines made a space."""
    return re.sub(r"[^\n]", " ", match.group(0))


def function_name(header: str):
    """The name a function definition's header declares, or None."""
    methods = list(OBJC_METHOD.finditer(header))
    if methods:
        method = header[methods[-1].start():].strip()[1:]
        while "(" in method:
            method = re.sub(r"\([^()]*\)", " ", method) if re.search(r"\([^()]*\)", method) else ""
        pieces = re.findall(r"([A-Za-z_]\w*)\s*:", method)
        if pieces:
            return "".join(piece + ":" for piece in pieces)
        words = re.findall(r"[A-Za-z_]\w*", method)
        return words[0] if words else None
    header = header.rstrip()
    if not header.endswith(")"):
        return None
    depth = 0
    for i in range(len(header) - 1, -1, -1):
        if header[i] == ")":
            depth += 1
        elif header[i] == "(":
            depth -= 1
            if depth == 0:
                name = IDENTIFIER.search(header[:i].rstrip())
                return name.group(0) if name else None
    return None


def functions(structure: str) -> list:
    """[(header start, body start, body end, name)] of the function definitions."""
    spans = []
    depth = 0
    boundary = 0
    opened = None  # (header start, body start, name) of the top-level block open now
    for match in re.finditer(r"[{};]", structure):
        char, at = match.group(0), match.start()
        if char == "{":
            if depth == 0:
                opened = (boundary, at, function_name(structure[boundary:at]))
            depth += 1
        elif char == "}":
            depth = max(depth - 1, 0)
            if depth == 0:
                if opened and opened[2]:
                    spans.append((opened[0], opened[1], at + 1, opened[2]))
                opened = None
                boundary = at + 1
        elif depth == 0:
            boundary = at + 1
    return spans


def file_sites(text: str) -> list:
    """[(function, call, line, calls a helper)] of the spawn calls in one file's text."""
    if not CALL.search(text):
        return []
    code = CODE_SPAN.sub(blank, text)
    structure = DIRECTIVE.sub(blank, code)
    spans = functions(structure)
    sites = []
    for match in CALL.finditer(code):
        at, call = match.start(), match.group(1)
        function, helper = "-", False
        for start, body, end, name in spans:
            if body <= at < end or (start <= at < body and structure[at:match.end()] == match.group(0)):
                function, helper = name, bool(HELPER.search(code, body, end))
                break
        sites.append((function, call, code.count("\n", 0, at) + 1, helper))
    return sites


def find_sites(src: Path) -> dict:
    """{(path, function, call): ([line...], every occurrence's function calls a helper)}."""
    found = {}
    for dirpath, dirnames, filenames in os.walk(src):
        rel_dir = Path(dirpath).relative_to(src).as_posix()
        dirnames[:] = sorted(d for d in dirnames
                             if d not in (".git", "tests") and not (rel_dir == "." and d == "tools"))
        for name in sorted(filenames):
            if not name.endswith(SUFFIXES):
                continue
            path = Path(dirpath) / name
            rel = path.relative_to(src).as_posix()
            text = path.read_bytes().decode("utf-8", errors="replace")
            for function, call, line, helper in file_sites(text):
                lines, handled = found.get((rel, function, call), ([], True))
                found[(rel, function, call)] = (lines + [line], handled and helper)
    return found


def read_sites(path: Path) -> dict:
    """{(path, function, call): handling} from the list; ValueError on a bad line."""
    listed = {}
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip() or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 5 or not all(field.strip() for field in fields):
            raise ValueError(f"line {number}: expected path<TAB>function<TAB>call<TAB>handling<TAB>reason")
        if fields[3] not in HANDLINGS:
            raise ValueError(f"line {number}: handling '{fields[3]}' is not one of {', '.join(HANDLINGS)}")
        key = tuple(fields[:3])
        if key in listed:
            raise ValueError(f"line {number}: {' '.join(key)} is listed twice")
        listed[key] = fields[3]
    return listed


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Check every spawn call in a renamed engine tree.")
    parser.add_argument("src", type=Path)
    parser.add_argument("--sites", type=Path, required=True)
    args = parser.parse_args(argv)
    if not args.src.is_dir():
        print(f"spawn_sites.py: {args.src} is not a folder", file=sys.stderr)
        return 2
    try:
        listed = read_sites(args.sites)
    except OSError as error:
        print(f"spawn_sites.py: {error}", file=sys.stderr)
        return 2
    except ValueError as error:
        print(f"spawn_sites.py: {args.sites} {error}", file=sys.stderr)
        return 2
    found = find_sites(args.src)
    problems = []
    for key in sorted(found):
        lines, helper = found[key]
        where = f"(line {', '.join(map(str, lines))})"
        if key not in listed:
            problems.append(f"unlisted {' '.join(key)} {where}")
        elif listed[key] == "drops-aliases" and not (helper and key[1] != "-"):
            problems.append(f"unhandled {' '.join(key)} {where}: its function calls no ano_env_*_aliases helper")
    problems += [f"unused {' '.join(key)}" for key in sorted(listed) if key not in found]
    for problem in problems:
        print(problem)
    counts = ", ".join(f"{sum(listed.get(key) == h for key in found)} {h}" for h in HANDLINGS)
    print(f"spawn sites: {len(found)} ({counts}), {len(problems)} problems")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
