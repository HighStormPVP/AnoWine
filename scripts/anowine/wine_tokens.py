#!/usr/bin/env python3
"""List every "wine" token in a runtime tree or a bottle.

Usage: wine_tokens.py ROOT... --out FILE.tsv [--allowlist FILE] [--gate]

A token is a maximal run of [A-Za-z0-9_] that contains "wine" in any case.
Tokens are taken from path names, symlink names and symlink targets, and from
file contents: ASCII text and UTF-16LE text (as in Windows resources and wide
strings). Folders behind symlinks are not entered.

The TSV has one row per token: token, class, count, files, example, where
class is `allowlisted:<category>` (from the allowlist), `not-wine-candidate`
(every occurrence is spelled exactly "WinE", as in WinExec, or follows a
letter other than the end of "lib", as in "twine") or `wine`.

It exits 0 unless the allowlist is malformed (exit 1) or, with --gate, a token
is not on the allowlist (exit 1, the tokens printed). The allowlist has one
entry per line, `token<TAB>category<TAB>reason`, with `#` comments; categories
are exactly CATEGORIES below. An entry with a space is a phrase of a license
notice or an alias (category `license` or `alias`, as the "Wine builtin DLL"
mark Apple's DLLs carry): its occurrences are blanked before tokens
are taken (Latin-1, UTF-8 and UTF-16LE), so its "Wine" is allowed there and
nowhere else. An entry with a slash is the repo URL (category `code-only`
only), blanked the same way: in a font's name table the URL runs straight
into the next record, so a token would not match.
"""
import argparse
import os
import re
import sys
from collections import Counter
from pathlib import Path

CATEGORIES = ("not-wine", "alias", "apple", "license", "code-only", "mono-internal")
TOKEN_BYTES = frozenset(b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_")
TOKEN_TEXT = re.compile(r"[A-Za-z0-9_]+")
WINE_ASCII = re.compile(rb"(?i)wine")
WINE_UTF16 = re.compile(rb"(?i)w\x00i\x00n\x00e\x00")
CHUNK = 1 << 20
MAX_CARRY = 1 << 20


def tokens_in_name(name: str) -> list:
    """Tokens containing "wine" in a file name, link target or other text."""
    return [token for token in TOKEN_TEXT.findall(name) if "wine" in token.lower()]


def _ascii_tokens(buf: bytes) -> list:
    tokens, taken_to = [], 0
    for match in WINE_ASCII.finditer(buf):
        if match.start() < taken_to:
            continue
        start, end = match.start(), match.end()
        while start > 0 and buf[start - 1] in TOKEN_BYTES:
            start -= 1
        while end < len(buf) and buf[end] in TOKEN_BYTES:
            end += 1
        tokens.append(buf[start:end].decode("ascii"))
        taken_to = end
    return tokens


def _utf16_tokens(buf: bytes) -> list:
    tokens, taken_to = [], 0
    for match in WINE_UTF16.finditer(buf):
        if match.start() < taken_to:
            continue
        start, end = match.start(), match.end()
        # A character whose own previous byte is printable belongs to ASCII
        # text that happens to end in a NUL ("call\0" before UTF-16 "Wine").
        while (start >= 2 and buf[start - 1] == 0 and buf[start - 2] in TOKEN_BYTES
               and not (start >= 3 and 0x20 <= buf[start - 3] <= 0x7E)):
            start -= 2
        while end + 1 < len(buf) and buf[end] in TOKEN_BYTES and buf[end + 1] == 0:
            end += 2
        tokens.append(buf[start:end].decode("utf-16-le"))
        taken_to = end
    return tokens


PHRASE_ENCODINGS = (("latin-1", b" "), ("utf-8", b" "), ("utf-16-le", b" \x00"))


def _encoded(phrase: str):
    """(bytes, space) for each form a phrase takes in files: Latin-1 (as Mac
    Roman for the copyright sign in font records), UTF-8 and UTF-16LE."""
    forms = {}
    for encoding, space in PHRASE_ENCODINGS:
        try:
            forms.setdefault(phrase.encode(encoding), space)
        except UnicodeEncodeError:
            pass
    return forms.items()


def _blank(buf: bytes, phrases) -> bytes:
    """Allowlisted phrases (license lines) become spaces."""
    for phrase in phrases:
        for encoded, space in _encoded(phrase):
            buf = buf.replace(encoded, space * (len(encoded) // len(space)))
    return buf


def tokens_in_bytes(data: bytes, phrases=()) -> Counter:
    """Tokens containing "wine" in ASCII and UTF-16LE text inside data."""
    data = _blank(data, phrases)
    return Counter(_ascii_tokens(data)) + Counter(_utf16_tokens(data))


def _safe_cut(buf: bytes) -> int:
    """An offset before which no token can continue past the end of buf."""
    cut = len(buf)
    moved = True
    while moved and cut > 0:
        moved = False
        while cut > 0 and buf[cut - 1] in TOKEN_BYTES:
            cut -= 1
            moved = True
        while cut >= 2 and buf[cut - 1] == 0 and buf[cut - 2] in TOKEN_BYTES:
            cut -= 2
            moved = True
    return max(cut, len(buf) - MAX_CARRY)


def tokens_in_file(path: Path, chunk: int = CHUNK, phrases=()) -> tuple:
    """(ASCII counts, UTF-16 counts) for one file, read in chunks; a token
    that crosses a chunk edge is carried into the next chunk whole, and so is
    the tail where an allowlisted phrase could still be incomplete."""
    ascii_counts, utf16_counts = Counter(), Counter()
    hold = max((len(encoded) for p in phrases for encoded, _ in _encoded(p)), default=0)
    carry = b""
    with open(path, "rb") as fh:
        while True:
            block = fh.read(chunk)
            buf = _blank(carry + block, phrases)
            if not block:
                cut = len(buf)
            else:
                cut = _safe_cut(buf[:max(0, len(buf) - hold)])
            ascii_counts.update(_ascii_tokens(buf[:cut]))
            utf16_counts.update(_utf16_tokens(buf[:cut]))
            carry = buf[cut:]
            if not block:
                return ascii_counts, utf16_counts


def _looks_not_wine(token: str) -> bool:
    for match in re.finditer(r"(?i)wine", token):
        before = token[:match.start()]
        if match.group() == "WinE":
            continue
        if before and before[-1].isalpha() and not before.lower().endswith("lib"):
            continue
        return False
    return True


def classify_token(token: str, allow: dict) -> str:
    if token in allow:
        return f"allowlisted:{allow[token][0]}"
    return "not-wine-candidate" if _looks_not_wine(token) else "wine"


def load_allowlist(path: Path) -> dict:
    """{token: (category, reason)}; ValueError names the first bad line."""
    allow = {}
    for number, line in enumerate(Path(path).read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 3:
            raise ValueError(f"line {number}: want token<TAB>category<TAB>reason, got {len(fields)} field(s)")
        token, category, reason = (field.strip() for field in fields)
        if "/" in token:
            if category != "code-only" or not tokens_in_name(token):
                raise ValueError(f"line {number}: a URL must be the repo URL (code-only) with a wine token: {token!r}")
        elif " " in token:
            if category not in ("license", "alias") or not tokens_in_name(token):
                raise ValueError(f"line {number}: a phrase must be a license line or an alias with a wine token: "
                                 f"{token!r}")
        elif not tokens_in_name(token) or tokens_in_name(token) != [token]:
            raise ValueError(f"line {number}: {token!r} is not a single wine token")
        if category not in CATEGORIES:
            raise ValueError(f"line {number}: unknown category {category!r} (allowed: {', '.join(CATEGORIES)})")
        if not reason:
            raise ValueError(f"line {number}: {token} has no reason")
        if token in allow:
            raise ValueError(f"line {number}: {token} is listed twice")
        allow[token] = (category, reason)
    return allow


class _Inventory:
    def __init__(self, phrases=()):
        self.phrases = tuple(phrases)
        self.count = Counter()
        self.files = {}
        self.example = {}
        self.by_source = Counter()  # (root, "names" | "ascii" | "utf16") -> occurrences

    def add(self, root: str, where: str, source: str, counts):
        for token, n in counts.items():
            self.count[token] += n
            self.files.setdefault(token, set()).add(where)
            self.example.setdefault(token, f"{where} ({source})")
            self.by_source[(root, source)] += n

    def scan(self, root: Path):
        label = root.name or str(root)

        def visit(folder: Path, rel: str):
            with os.scandir(folder) as entries:
                for entry in sorted(entries, key=lambda e: e.name):
                    where = f"{label}/{rel}{entry.name}"
                    names = Counter(tokens_in_name(entry.name))
                    if entry.is_symlink():
                        names.update(tokens_in_name(os.readlink(entry.path)))
                        self.add(label, where, "names", names)
                    elif entry.is_dir(follow_symlinks=False):
                        self.add(label, where, "names", names)
                        visit(Path(entry.path), f"{rel}{entry.name}/")
                    else:
                        self.add(label, where, "names", names)
                        if entry.is_file(follow_symlinks=False):
                            ascii_counts, utf16_counts = tokens_in_file(Path(entry.path), phrases=self.phrases)
                            self.add(label, where, "ascii", ascii_counts)
                            self.add(label, where, "utf16", utf16_counts)

        visit(root, "")


def main(argv: list) -> int:
    parser = argparse.ArgumentParser(prog="wine_tokens.py", description="List every wine token.")
    parser.add_argument("roots", nargs="+", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--allowlist", type=Path)
    parser.add_argument("--gate", action="store_true", help="exit 1 if any token is not on the allowlist")
    args = parser.parse_args(argv)
    try:
        allow = load_allowlist(args.allowlist) if args.allowlist else {}
    except ValueError as error:
        print(f"wine_tokens.py: {args.allowlist}: {error}", file=sys.stderr)
        return 1
    inventory = _Inventory(phrases=[token for token in allow if " " in token or "/" in token])
    for root in args.roots:
        inventory.scan(root)
    rows = sorted(inventory.count.items(), key=lambda item: (-item[1], item[0]))
    with open(args.out, "w", encoding="utf-8", newline="\n") as out:
        out.write("token\tclass\tcount\tfiles\texample\n")
        for token, n in rows:
            out.write(f"{token}\t{classify_token(token, allow)}\t{n}\t{len(inventory.files[token])}"
                      f"\t{inventory.example[token]}\n")
    classes = Counter(classify_token(token, allow).split(":")[0] for token in inventory.count)
    print(f"{len(rows)} distinct tokens, {sum(inventory.count.values())} occurrences; "
          + ", ".join(f"{name} {n}" for name, n in sorted(classes.items())))
    for root in args.roots:
        label = root.name or str(root)
        parts = [f"{source} {inventory.by_source[(label, source)]}" for source in ("names", "ascii", "utf16")]
        print(f"{label}: occurrences by source: {', '.join(parts)}")
    if args.gate:
        hits = [(token, n) for token, n in rows if not classify_token(token, allow).startswith("allowlisted")]
        if hits:
            print(f"gate: {len(hits)} tokens ({sum(n for _, n in hits)} occurrences) are not on the allowlist")
            for token, n in hits[:200]:
                print(f"{token}\t{n}\t{inventory.example[token]}")
            return 1
        print("gate: every token is on the allowlist")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
