"""Swift string literals, read the way the compiler reads them (Plan 3c-4b).

`literals(text)` yields every string literal outside comments, with its
interpolations kept apart, so a caller can tell text from code and can rewrite
the text without touching the code. `key_of(literal)` is the string a
localization lookup sees: escapes decoded, a multi-line literal's indentation
and line continuations applied, each interpolation as INTERP.
"""
import re
from dataclasses import dataclass, field

# What an interpolation becomes in a key (a catalog key has %@, %lld, ... there).
INTERP = "\x01"
# A printf-style specifier, as a string catalog key carries them.
SPECIFIER = re.compile(r"%(?:\d+\$)?[-+ #0']*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|h|ll|l|q|L|z|t|j)?"
                       r"[@dDiuUxXoOfFeEgGcCsSpaA]")


@dataclass
class Literal:
    start: int          # offset of the opening delimiter (its first #, if raw)
    end: int            # offset just past the closing delimiter
    hashes: int         # number of # around a raw string
    multiline: bool
    # ("text", raw source) and ("code", the source inside \( ... )), in order.
    parts: list = field(default_factory=list)
    # Offsets into the file of each part's raw source.
    spans: list = field(default_factory=list)

    @property
    def has_code(self) -> bool:
        return any(kind == "code" for kind, _ in self.parts)


class SwiftLexError(ValueError):
    pass


def _skip_block_comment(text: str, i: int) -> int:
    depth = 0
    while i < len(text):
        if text.startswith("/*", i):
            depth += 1
            i += 2
        elif text.startswith("*/", i):
            depth -= 1
            i += 2
            if depth == 0:
                return i
        else:
            i += 1
    return i


def _string_at(text: str, i: int):
    """The literal whose delimiter starts at i (a # or a "), or None."""
    j = i
    while j < len(text) and text[j] == "#":
        j += 1
    hashes = j - i
    if not text.startswith('"', j):
        return None
    multiline = text.startswith('"""', j)
    body = j + (3 if multiline else 1)
    closing = ('"""' if multiline else '"') + "#" * hashes
    escape = "\\" + "#" * hashes
    lit = Literal(start=i, end=-1, hashes=hashes, multiline=multiline)
    k, text_start = body, body
    while True:
        if k >= len(text):
            raise SwiftLexError(f"unterminated string at offset {i}")
        if not multiline and text[k] == "\n":
            raise SwiftLexError(f"newline in a single-line string at offset {i}")
        if text.startswith(escape, k):
            after = k + len(escape)
            if text.startswith("(", after):
                lit.parts.append(("text", text[text_start:k]))
                lit.spans.append((text_start, k))
                code_start = after + 1
                code_end = _code_until_paren(text, code_start)
                lit.parts.append(("code", text[code_start:code_end]))
                lit.spans.append((code_start, code_end))
                k = code_end + 1
                text_start = k
                continue
            k = after + 1
            continue
        if text.startswith(closing, k):
            lit.parts.append(("text", text[text_start:k]))
            lit.spans.append((text_start, k))
            lit.end = k + len(closing)
            return lit
        k += 1


def _code_until_paren(text: str, i: int) -> int:
    """Offset of the ) that closes an interpolation whose code starts at i."""
    depth = 1
    while i < len(text):
        c = text[i]
        if text.startswith("//", i):
            i = text.find("\n", i)
            i = len(text) if i < 0 else i
            continue
        if text.startswith("/*", i):
            i = _skip_block_comment(text, i)
            continue
        if c == '"' or (c == "#" and re.match(r'#+"', text[i:])):
            lit = _string_at(text, i)
            if lit:
                i = lit.end
                continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    raise SwiftLexError("unterminated interpolation")


def literals(text: str):
    """Every string literal outside comments, left to right (not those nested
    inside another literal's interpolation)."""
    i = 0
    while i < len(text):
        if text.startswith("//", i):
            i = text.find("\n", i)
            if i < 0:
                return
            continue
        if text.startswith("/*", i):
            i = _skip_block_comment(text, i)
            continue
        c = text[i]
        if c == '"' or (c == "#" and re.match(r'#+"', text[i:])
                        and (i == 0 or not (text[i - 1].isalnum() or text[i - 1] == "_"))):
            lit = _string_at(text, i)
            if lit:
                yield lit
                i = lit.end
                continue
        i += 1


_ESCAPES = {"\\": "\\", '"': '"', "'": "'", "n": "\n", "t": "\t", "r": "\r", "0": "\0"}


def _unescape(raw: str, hashes: int) -> str:
    escape = "\\" + "#" * hashes
    out, i = [], 0
    while i < len(raw):
        if raw.startswith(escape, i):
            j = i + len(escape)
            c = raw[j] if j < len(raw) else ""
            if c in _ESCAPES:
                out.append(_ESCAPES[c])
                i = j + 1
                continue
            if c == "u" and raw.startswith("{", j + 1):
                close = raw.index("}", j)
                out.append(chr(int(raw[j + 2:close], 16)))
                i = close + 1
                continue
            out.append(raw[i:j + 1])
            i = j + 1
            continue
        out.append(raw[i])
        i += 1
    return "".join(out)


def key_of(lit: Literal) -> str:
    """The string a localization lookup sees, each interpolation as INTERP."""
    raw = "".join(INTERP if kind == "code" else source for kind, source in lit.parts)
    if lit.multiline:
        lines = raw.split("\n")
        indent = lines[-1]
        body = lines[1:-1]
        escape = "\\" + "#" * lit.hashes
        joined = []
        for n, line in enumerate(body):
            line = line[len(indent):] if line.startswith(indent) else line.lstrip(" \t")
            stripped = line.rstrip(" \t")
            # A line ending in a lone escape continues on the next line.
            trailing = len(stripped) - len(stripped.rstrip("\\"))
            if lit.hashes == 0 and trailing % 2 == 1 and n < len(body) - 1:
                joined.append(stripped[:-1])
            elif lit.hashes and stripped.endswith(escape) and n < len(body) - 1:
                joined.append(stripped[:-len(escape)])
            else:
                joined.append(line + ("\n" if n < len(body) - 1 else ""))
        raw = "".join(joined)
    return _unescape(raw, lit.hashes)


def normalize_key(key: str) -> str:
    """A catalog key with each format specifier as INTERP and %% as %."""
    return SPECIFIER.sub(INTERP, key).replace("%%", "%")


def line_of(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1
