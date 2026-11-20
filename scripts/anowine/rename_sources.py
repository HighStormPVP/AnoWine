#!/usr/bin/env python3
"""Rename a Wine source tree by the owner's naming rule (Plan 3c-1).

Usage: rename_sources.py SRC [--protect FILE] --map FILE [--report FILE]

The rule, case-sensitive, in this order:
  1. protected text stays as it is (Windows names that only contain the
     letters, plain words, license phrases);
  2. the fixed map: program names (ano-cfg), reverse-DNS identities, URLs,
     misspellings the case rule cannot know (WIne);
  3. wine -> ano, Wine -> Ano, WINE -> ANO.
It renames path names and the contents of every text file. In C-family
files (CODE_SUFFIXES) a program name is mapped inside string literals and
where it names a file (winecfg.ico); elsewhere it is an identifier (a debug
channel such as winedbg) and follows the case rule, so it stays a valid C name.
A character array ({'w','i','n','e',0}) is renamed as a string. URL rules
ignore case; a gettext string wrapped over lines is joined first, so a URL
is seen whole. Binary files that still say "wine" are listed, not changed.
Exit 1 when two paths would get the same name, a protected entry never
occurs in the tree, or anohq (a host Ano does not own) is left anywhere but
tests and docs that are not built.
"""
import argparse
import os
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

CASES = {"wine": "ano", "Wine": "Ano", "WINE": "ANO"}
CASE_RE = re.compile("wine|Wine|WINE")
IDENT = "A-Za-z0-9_"
URL_TAIL = r"(?:/[^\s\"'<>()\\]*)?"
PROTECT_KINDS = ("substring", "word", "license")
MAP_KINDS = ("program", "identity", "url", "text")
CODE_SUFFIXES = frozenset((".c", ".h", ".m", ".mm", ".cpp", ".cc", ".cxx", ".hpp", ".y", ".l", ".idl", ".rc"))
# Comments, string literals and character literals of C-family code, left to
# right, so a quote inside a comment or a character literal opens no string.
CODE_SPAN = re.compile(r"""//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'""", re.S)
# Wine spells some strings as character arrays ({'w','i','n','e',0}): a run of
# two or more character literals separated by commas is renamed as a string.
CHAR = r"""'(?:\\[\\'"ntr0]|[^'\\\n])'"""
CHAR_RUN = re.compile(CHAR + r"(?:\s*,\s*" + CHAR + r")+")
CHAR_ESCAPES = {"\\": "\\", "'": "'", '"': '"', "n": "\n", "t": "\t", "r": "\r", "0": "\0"}
CHAR_SPELL = {value: "\\" + key for key, value in CHAR_ESCAPES.items() if key != '"'}
# A gettext string and its continuation lines.
PO_STRING = re.compile(r'^((?:msgctxt|msgid|msgid_plural|msgstr(?:\[\d+\])?) )"(.*)"\n((?:".*"\n)+)', re.M)
# anohq would be a host Ano does not own; tests and docs that are not built may say it.
FOREIGN_HOST = re.compile("anohq", re.I)
NOT_SHIPPED = re.compile(r"(^|/)(tests|documentation)/|^tools/gitlab/|\.man\.in$|"
                         r"(^|/)(README[^/]*|MAINTAINERS|\.mailmap|ANNOUNCE[^/]*|AUTHORS)$")
BINARY_WINE = re.compile(
    b"|".join(re.escape(w.encode(enc)) for w in CASES for enc in ("ascii", "utf-16-le", "utf-16-be")))


@dataclass
class Rules:
    protect: re.Pattern
    protect_texts: list
    stages: list  # (pattern, replacement, file-name pattern of a program or None), in order
    used: set = field(default_factory=set)


@dataclass
class Report:
    renamed_paths: int = 0
    changed_files: int = 0
    binary_with_wine: list = field(default_factory=list)
    conflicts: list = field(default_factory=list)


def _rows(path, kinds, what):
    rows = []
    for number, line in enumerate(Path(path).read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip() or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 3 or not all(fields):
            raise ValueError(f"{path} line {number}: expected three tab-separated fields")
        if fields[2] not in kinds and fields[1] not in kinds:
            raise ValueError(f"{path} line {number}: unknown kind")
        if not re.search("wine", fields[0], re.IGNORECASE):
            raise ValueError(f"{path} line {number}: {what} without wine: {fields[0]}")
        rows.append(fields)
    return rows


def load_rules(protect, mapping: Path) -> Rules:
    """protect may be None: a tree with no protected text (DXVK, DXMT)."""
    texts, parts = [], []
    for text, kind, _ in _rows(protect, PROTECT_KINDS, "protected text") if protect else []:
        if kind not in PROTECT_KINDS:
            raise ValueError(f"{protect}: unknown kind {kind} for {text}")
        texts.append(text)
        escaped = re.escape(text)
        if kind == "substring":
            parts.append((len(text), escaped))
        else:
            parts.append((len(text), f"(?<![{IDENT}]){escaped}(?![{IDENT}])"))
    parts.sort(key=lambda p: -p[0])
    protect_re = re.compile("|".join(p for _, p in parts)) if parts else re.compile(r"(?!x)x")

    stages = []
    rows = _rows(mapping, MAP_KINDS, "mapped name")
    for old, new, kind in sorted(rows, key=lambda r: -len(r[0])):
        if kind not in MAP_KINDS:
            raise ValueError(f"{mapping}: unknown kind {kind} for {old}")
        escaped = re.escape(old)
        if kind == "program":
            # A name right after an escape in a string ("\twinedbg") counts too.
            pattern = rf"(?:(?<![{IDENT}])|(?<=\\[ntr])){escaped}(?![{IDENT}])"
        elif kind in ("identity", "text"):  # text: a misspelling (WIne), anywhere
            pattern = escaped
        elif old.count(".") > 1:  # a full host: bugs.winehq.org
            pattern = f"(?:https?://)?{escaped}{URL_TAIL}"
        else:  # a domain: any host under it
            pattern = f"(?:https?://)?(?:[A-Za-z0-9-]+\\.)*{escaped}{URL_TAIL}"
        # In code, outside strings, only a file name counts (winecfg.ico).
        file_name = re.compile(pattern + r"(?=\.[A-Za-z])") if kind == "program" else None
        # A host name has no case: WINEHQ.ORG and WineHQ.org are the same host.
        stages.append((re.compile(pattern, re.I if kind == "url" else 0), new, file_name))
    return Rules(protect=protect_re, protect_texts=texts, stages=stages)


def rename_text(text: str, rules: Rules, code: bool = False) -> str:
    saved = []

    def stash(value):
        saved.append(value)
        return f"{len(saved) - 1}"

    def keep(match):
        rules.used.add(match.group(0))
        return stash(match.group(0))

    def in_code(pattern, file_name, new, text):
        """Strings get the program name; code and comments only file names."""
        parts, pos = [], 0
        for match in CODE_SPAN.finditer(text):
            parts.append(file_name.sub(lambda _m: stash(new), text[pos:match.start()]))
            literal = match.group(0)
            parts.append((pattern if literal[0] in "\"'" else file_name).sub(lambda _m: stash(new), literal))
            pos = match.end()
        parts.append(file_name.sub(lambda _m: stash(new), text[pos:]))
        return "".join(parts)

    def char_run(match):
        run = match.group(0)
        old = "".join(CHAR_ESCAPES[lit[2]] if lit[1] == "\\" else lit[1] for lit in re.findall(CHAR, run))
        new = rename_text(old, rules)
        if new == old:
            return run
        return stash(",".join("'" + CHAR_SPELL.get(c, c) + "'" for c in new))

    out = rules.protect.sub(keep, CHAR_RUN.sub(char_run, text) if code else text)
    for pattern, new, file_name in rules.stages:
        if code and file_name:
            out = in_code(pattern, file_name, new, out)
        else:
            out = pattern.sub(lambda _m, new=new: stash(new), out)
    out = CASE_RE.sub(lambda m: CASES[m.group(0)], out)
    return re.sub("(\\d+)", lambda m: saved[int(m.group(1))], out)


def rename_path(rel: str, rules: Rules) -> str:
    return "/".join(rename_text(part, rules) for part in rel.split("/"))


def _decode(data):
    try:
        return data.decode("utf-8"), "utf-8"
    except UnicodeDecodeError:
        return data.decode("latin-1"), "latin-1"


def rename_tree(src: Path, rules: Rules) -> Report:
    src = Path(src)
    report = Report()
    entries = []
    for dirpath, dirnames, filenames in os.walk(src):
        dirnames[:] = sorted(d for d in dirnames if not (dirpath == str(src) and d == ".git"))
        rel_dir = os.path.relpath(dirpath, src).replace(os.sep, "/")
        for name in sorted(filenames) + [d for d in dirnames if os.path.islink(os.path.join(dirpath, d))]:
            path = os.path.join(dirpath, name)
            rel = name if rel_dir == "." else f"{rel_dir}/{name}"
            if os.path.islink(path):
                target = os.readlink(path)
                new_target = rename_path(target.replace(os.sep, "/"), rules)
                if new_target != target:
                    os.remove(path)
                    os.symlink(new_target, path)
                    report.changed_files += 1
                continue
            data = Path(path).read_bytes()
            if b"\0" in data[:8192]:
                if BINARY_WINE.search(data):
                    report.binary_with_wine.append(rename_path(rel, rules))
                continue
            text, encoding = _decode(data)
            source = join_po_strings(text) if name.endswith((".po", ".pot")) else text
            new = rename_text(source, rules, code=os.path.splitext(name)[1] in CODE_SUFFIXES)
            if new != text:
                Path(path).write_bytes(new.encode(encoding))
                report.changed_files += 1
        for name in dirnames:
            entries.append(name if rel_dir == "." else f"{rel_dir}/{name}")
        for name in filenames:
            entries.append(name if rel_dir == "." else f"{rel_dir}/{name}")

    for rel in sorted(entries, key=lambda r: (-r.count("/"), r)):
        parent, _, name = rel.rpartition("/")
        new_name = rename_text(name, rules)
        if new_name == name:
            continue
        old_path = src / rel
        new_path = old_path.parent / new_name
        if new_path.exists() or new_path.is_symlink():
            report.conflicts.append(f"{rel} -> {parent + '/' if parent else ''}{new_name}: already exists")
            continue
        os.rename(old_path, new_path)
        report.renamed_paths += 1
    report.binary_with_wine.sort()
    return report


def join_po_strings(text: str) -> str:
    """Put each gettext string on one line: gettext wraps long strings, and a
    URL split over two lines would escape the URL rule."""
    return PO_STRING.sub(lambda m: m.group(1) + '"' + m.group(2)
                         + "".join(line[1:-1] for line in m.group(3).splitlines()) + '"\n', text)


def foreign_hosts(src: Path) -> list:
    """Lines outside tests and unbuilt docs that name anohq ("rel:line")."""
    src = Path(src)
    found = []
    for dirpath, dirnames, filenames in os.walk(src):
        dirnames[:] = sorted(d for d in dirnames if d != ".git")
        for name in sorted(filenames):
            path = Path(dirpath) / name
            rel = path.relative_to(src).as_posix()
            if NOT_SHIPPED.search(rel) or path.is_symlink():
                continue
            data = path.read_bytes()
            if b"\0" in data[:8192]:
                continue
            for number, line in enumerate(_decode(data)[0].splitlines(), 1):
                if FOREIGN_HOST.search(line):
                    found.append(f"{rel}:{number}")
    return found


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Rename a Wine source tree by the owner's naming rule.")
    parser.add_argument("src", type=Path)
    parser.add_argument("--protect", type=Path, help="protected text (none if omitted)")
    parser.add_argument("--map", type=Path, required=True, dest="mapping")
    parser.add_argument("--report", type=Path)
    args = parser.parse_args(argv)
    rules = load_rules(args.protect, args.mapping)
    report = rename_tree(args.src, rules)
    unused = [t for t in rules.protect_texts if t not in rules.used]
    lines = [f"renamed paths: {report.renamed_paths}", f"changed files: {report.changed_files}",
             f"binary files with wine: {len(report.binary_with_wine)}"]
    lines += [f"binary\t{rel}" for rel in report.binary_with_wine]
    lines += [f"conflict\t{c}" for c in report.conflicts]
    lines += [f"unused protected text\t{t}" for t in unused]
    hosts = foreign_hosts(args.src)
    lines += [f"foreign host\t{h}" for h in hosts]
    output = "\n".join(lines) + "\n"
    if args.report:
        args.report.write_text(output, encoding="utf-8")
    sys.stdout.write(output)
    return 1 if report.conflicts or unused or hosts else 0


if __name__ == "__main__":
    sys.exit(main())
