#!/usr/bin/env python3
"""Make Libraries/ano-tricks from winetricks 20260125 (Plan 3c-3).

Usage: make_ano_tricks.py [--check] [--upstream FILE] [--out FILE]

1. Take upstream's src/winetricks at tag 20260125 (downloaded, or the copy
   --upstream names) and check its SHA-256.
2. Drop the verbs that download from other people's paths named after Wine
   (DROP_VERBS): renamed, those paths would not exist, or would be someone
   else's to claim. The app uses none of them.
3. Edit: the update check, self-update and stats report become stubs (they
   reach the network outside the bottle's proxy, and the self-update would
   fetch from a GitHub account the rule names but Ano does not own); the
   cache moves to Ano's cache folder; three comments linking other sites'
   pages about Wine go.
4. Stop if any URL that names Wine is left that no url rule of the map
   replaces with the repo URL.
5. Rename by the owner's rule (rename_sources.py): rename-map.txt and
   rename-protect-tricks.txt.
6. Write Libraries/ano-tricks, or with --check exit 1 if the committed file
   differs from what this makes.
"""
import argparse
import difflib
import hashlib
import os
import re
import sys
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from rename_sources import FOREIGN_HOST, load_rules, rename_text  # noqa: E402

UPSTREAM_URL = "https://raw.githubusercontent.com/Winetricks/winetricks/20260125/src/winetricks"
UPSTREAM_SHA256 = "431f82fc74000e6c864409f1d8fb495d696c03928808e3e8acffc45179312a7b"
OUT = HERE.parent.parent / "Libraries" / "ano-tricks"
REPO = "https://github.com/HighStormPVP/AnoWine"
SEPARATOR = "#" + "-" * 64 + "\n"

# galliumnine*: iXit/wine-nine-standalone (and Mesa's Gallium Nine, which a
# Mac does not have); ie7, ie8: files/winetest.cat from upstream's own repo,
# ie8_*: need ie8; otvdm*: otya128/winevdm; powershell: the
# powershell-wrapper-for-wine (powershell_core, PowerShell itself, stays).
DROP_VERBS = frozenset(["galliumnine"] + [f"galliumnine0{n}" for n in range(2, 11)]
                       + ["ie7", "ie8", "ie8_kb2936068", "ie8_tls12", "otvdm", "otvdm090", "powershell"])
DROP_HELPERS = frozenset(["galliumnine", "otvdm"])

NO_UPDATE = '    w_die "ano-tricks does not update itself: it comes with Ano, and Ano updates it."\n'
NO_NETWORK = "    # Ano: ano-tricks makes no update check and sends no statistics.\n    return\n"
STUBS = {
    "winetricks_check_update_availability": NO_UPDATE,
    "winetricks_selfupdate": NO_UPDATE,
    "winetricks_selfupdate_rollback": NO_UPDATE,
    "winetricks_latest_version_check": NO_NETWORK,
    "winetricks_stats_init": NO_NETWORK,
    "winetricks_stats_save": NO_NETWORK,
    "winetricks_stats_report": NO_NETWORK,
}
EDITS = (
    # The cache: Ano's cache folder, not ~/.cache (the script sets
    # XDG_CACHE_HOME to ~/.cache before its macOS default can apply).
    ('        W_CACHE="${W_CACHE:-${XDG_CACHE_HOME}/winetricks}"\n',
     '        W_CACHE="${W_CACHE:-${HOME}/Library/Caches/io.github.highstormpvp.Ano/ano-tricks}"\n'),
    ("    # See also https://code.google.com/p/winezeug/issues/detail?id=78\n", ""),
    ("    # https://github.com/seapear/AffinityOnLinux/blob/main/wine-dark-theme.reg\n", ""),
    ("    # https://bgstack15.ddns.net/blog/posts/2024/08/21/set-wine-theme-from-cli/\n", ""),
)

# Upstream's vcrun2022 copies msvcp140.dll out of the redistributables' cabinets
# itself (their installer keeps the builtin, whose version number is higher),
# but in the pinned 2022 redistributables the file is msvcp140.dll_x86 (a10) and
# msvcp140.dll_amd64 (a12): -F 'msvcp140.dll' extracts nothing and the verb
# leaves the builtin. (vcrun2019's cabinets name it msvcp140.dll.) If the name
# changes again, the mv fails the verb instead.
FUNCTION_EDITS = (
    ("load_vcrun2022",
     """    w_try_cabextract --directory="${W_SYSTEM32_DLLS}" "${W_TMP}/win32/a10" -F 'msvcp140.dll'\n""",
     """    # Ano: in the 2022 redistributable the file is msvcp140.dll_x86.\n"""
     """    w_try_cabextract --directory="${W_TMP}/win32" "${W_TMP}/win32/a10" -F 'msvcp140.dll_x86'\n"""
     """    w_try mv -f "${W_TMP}/win32/msvcp140.dll_x86" "${W_SYSTEM32_DLLS}/msvcp140.dll"\n"""),
    ("load_vcrun2022",
     """            w_try_cabextract --directory="${W_SYSTEM64_DLLS}" "${W_TMP}/win64/a12" -F 'msvcp140.dll'\n""",
     """            # Ano: in the 2022 redistributable the file is msvcp140.dll_amd64.\n"""
     """            w_try_cabextract --directory="${W_TMP}/win64" "${W_TMP}/win64/a12" -F 'msvcp140.dll_amd64'\n"""
     """            w_try mv -f "${W_TMP}/win64/msvcp140.dll_amd64" "${W_SYSTEM64_DLLS}/msvcp140.dll"\n"""),
)

METADATA = re.compile(r"^w_metadata ([A-Za-z0-9_]+) ", re.M)
FUNCTION = re.compile(r"^([A-Za-z0-9_]+)\(\)", re.M)
CALL = re.compile(r"\bw_(?:do_)?call\s+([A-Za-z0-9_]+)")
URL = re.compile(r"(?:https?://)?(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,}/[^\s\"'<>()\\]*")


def drop_verbs(text: str, verbs, helpers=()) -> str:
    """Remove each separator-delimited chunk that defines a verb in verbs or
    a helper_<name> for a name in helpers. Such a chunk may define nothing
    else; every verb and helper must be found; no kept code may call one."""
    verbs, helpers = set(verbs), set(helpers)
    kept, found = [], set()
    for chunk in text.split(SEPARATOR):
        defined = METADATA.findall(chunk)
        functions = FUNCTION.findall(chunk)
        hit = [v for v in defined if v in verbs] + [f for f in functions if f[len("helper_"):] in helpers
                                                    and f.startswith("helper_")]
        if not hit:
            kept.append(chunk)
            continue
        others = [v for v in defined if v not in verbs]
        others += [f for f in functions
                   if not (f.startswith("load_") and f[len("load_"):] in verbs)
                   and not (f.startswith("helper_") and f[len("helper_"):] in helpers)]
        if others:
            raise ValueError(f"the chunk of {hit[0]} also defines {', '.join(others)}")
        found.update(defined)
        found.update(f[len("helper_"):] for f in functions if f.startswith("helper_"))
    missing = sorted((verbs | helpers) - found)
    if missing:
        raise ValueError(f"not found: {', '.join(missing)}")
    out = SEPARATOR.join(kept)
    for name in CALL.findall(out):
        if name in verbs:
            raise ValueError(f"a kept verb still calls a dropped one: w_call {name}")
    for name in helpers:
        if re.search(rf"\bhelper_{name}\b", out):
            raise ValueError(f"kept code still uses helper_{name}")
    return out


def _function(text: str, name: str) -> re.Match:
    """The one definition of name() with its braces in column 0."""
    pattern = re.compile(rf"^{re.escape(name)}\(\)\n\{{\n(.*?)^\}}\n", re.M | re.S)
    matches = list(pattern.finditer(text))
    if len(matches) != 1:
        raise ValueError(f"expected one function {name}, found {len(matches)}")
    return matches[0]


def stub_function(text: str, name: str, body: str) -> str:
    """Replace the body of the function name()."""
    match = _function(text, name)
    return text[:match.start()] + f"{name}()\n{{\n{body}}}\n" + text[match.end():]


def replace_in_function(text: str, name: str, old: str, new: str) -> str:
    """replace_once inside the body of the function name() only."""
    match = _function(text, name)
    body = replace_once(match.group(1), old, new)
    return text[:match.start(1)] + body + text[match.end(1):]


def replace_once(text: str, old: str, new: str) -> str:
    count = text.count(old)
    if count != 1:
        raise ValueError(f"expected one {old!r}, found {count}")
    return text.replace(old, new)


def load_tricks_rules():
    return load_rules(HERE / "rename-protect-tricks.txt", HERE / "rename-map.txt")


def rename(text: str, rules) -> str:
    return rename_text(text, rules)


def wine_urls_left(text: str, rules) -> list:
    """URLs naming Wine that no url rule replaces with the repo URL."""
    left = []
    for match in URL.finditer(text):
        url = match.group(0)
        if re.search("wine", url, re.I) and not rename(url, rules).startswith(REPO):
            left.append(url)
    return left


def generate(upstream: str) -> str:
    text = drop_verbs(upstream, DROP_VERBS, DROP_HELPERS)
    for name, body in STUBS.items():
        text = stub_function(text, name, body)
    for old, new in EDITS:
        text = replace_once(text, old, new)
    for name, old, new in FUNCTION_EDITS:
        text = replace_in_function(text, name, old, new)
    rules = load_tricks_rules()
    left = wine_urls_left(text, rules)
    if left:
        raise ValueError("URLs naming Wine on hosts the map does not replace:\n  " + "\n  ".join(left))
    out = rename(text, rules)
    unused = [t for t in rules.protect_texts if t not in rules.used]
    if unused:
        raise ValueError(f"protected text never seen: {', '.join(unused)}")
    hosts = [line for line in out.splitlines() if FOREIGN_HOST.search(line)]
    if hosts:
        raise ValueError(f"a host Ano does not own: {hosts[0]}")
    return out


def read_upstream(path) -> str:
    if path:
        data = Path(path).read_bytes()
    else:
        with urllib.request.urlopen(UPSTREAM_URL, timeout=60) as response:
            data = response.read()
    digest = hashlib.sha256(data).hexdigest()
    if digest != UPSTREAM_SHA256:
        raise ValueError(f"upstream winetricks has SHA-256 {digest}, not {UPSTREAM_SHA256}")
    return data.decode("utf-8")


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Make Libraries/ano-tricks from winetricks 20260125.")
    parser.add_argument("--check", action="store_true", help="exit 1 if the committed file differs")
    parser.add_argument("--upstream", type=Path, help="a local copy of upstream's src/winetricks")
    parser.add_argument("--out", type=Path, default=OUT)
    args = parser.parse_args(argv)
    try:
        made = generate(read_upstream(args.upstream))
    except ValueError as error:
        print(f"make_ano_tricks.py: {error}", file=sys.stderr)
        return 1
    if args.check:
        committed = args.out.read_text(encoding="utf-8") if args.out.is_file() else ""
        if committed == made:
            print(f"{args.out.name}: made from upstream, equal to the committed file")
            return 0
        diff = difflib.unified_diff(committed.splitlines(), made.splitlines(), "committed", "made", lineterm="", n=1)
        print(f"{args.out}: differs from what make_ano_tricks.py makes:", file=sys.stderr)
        print("\n".join(list(diff)[:60]), file=sys.stderr)
        return 1
    args.out.write_bytes(made.encode("utf-8"))
    if os.name != "nt":
        os.chmod(args.out, 0o755)
    print(f"wrote {args.out} ({made.count(chr(10))} lines)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
