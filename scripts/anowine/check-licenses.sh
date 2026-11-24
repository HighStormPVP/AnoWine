#!/bin/bash
# Checks that Ano's runtime carries the license of everything in it (Plan 3c-5).
#
# Usage: check-licenses.sh <Libraries> [--manifest FILE]
#   FILE defaults to licenses.txt next to this script.
#
# The manifest has one line per component (# comments, blank lines):
#   component<TAB>version<TAB>spdx<TAB>source<TAB>license-files<TAB>covers<TAB>modified
# source is winecx, recipe, nix:<attribute>, url:<pinned URL> or
# payload:<folder>; license-files are paths inside that source, shipped as
# Ano/share/ano/licenses/<component>/<path>; covers are globs relative to
# Libraries/ (* stays inside one folder, ** crosses folders, **/ may be no
# folder at all), or - for a component built into another's files. A
# component may have no license files (-) only when its spdx is NOASSERTION:
# its source publishes no license, and the check says so.
#
# Exit 1, naming each cause, when:
#   - a component's license text is missing or empty under Ano/share/ano/licenses;
#   - Ano/share/ano/NOTICES has no table row ("<component> | ...") for a component;
#   - a regular file under Libraries/ matches no component's globs. Components
#     match in manifest order and the first match wins.
# Exit 2 when the manifest is malformed. Symlinks are not files of their own.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
exec python3 - "$HERE/licenses.txt" "$@" << 'PY'
import os
import re
import sys

LICENSES = "Ano/share/ano/licenses"
NOTICES = "Ano/share/ano/NOTICES"
SOURCE = re.compile(r"^(winecx|recipe|nix:\S+|url:\S+|payload:\S+)$")
NAME = re.compile(r"^[a-z0-9][a-z0-9._+-]*$")


def usage(message):
    print(f"check-licenses.sh: {message}", file=sys.stderr)
    print("usage: check-licenses.sh <Libraries> [--manifest FILE]", file=sys.stderr)
    sys.exit(2)


def glob_regex(glob):
    """* stays inside one folder, ** crosses folders, **/ may be no folder."""
    out, i = [], 0
    while i < len(glob):
        if glob.startswith("**/", i):
            out.append("(?:.*/)?")
            i += 3
        elif glob.startswith("**", i):
            out.append(".*")
            i += 2
        elif glob[i] == "*":
            out.append("[^/]*")
            i += 1
        elif glob[i] == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(glob[i]))
            i += 1
    return re.compile("".join(out) + r"\Z")


def load(path):
    """[(component, spdx, files, [regex], covers-text)]; exit 2 on a bad line."""
    components, seen = [], set()
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except OSError as error:
        usage(f"cannot read the manifest: {error}")
    for number, line in enumerate(lines, 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        fields = line.split("\t")
        where = f"{path}:{number}"
        if len(fields) != 7:
            usage(f"{where}: want 7 fields (component, version, spdx, source, license-files, covers, "
                  f"modified), got {len(fields)}")
        name, version, spdx, source, files, covers, modified = (field.strip() for field in fields)
        if not NAME.match(name):
            usage(f"{where}: bad component name {name!r}")
        if name in seen:
            usage(f"{where}: {name} is listed twice")
        seen.add(name)
        if not version or not spdx or not modified:
            usage(f"{where}: {name} needs a version, an spdx id and a modified statement")
        if not SOURCE.match(source):
            usage(f"{where}: {name} has a bad source {source!r}")
        if files == "-":
            if spdx != "NOASSERTION":
                usage(f"{where}: {name} has no license files, so its spdx must be NOASSERTION")
            files = []
        else:
            files = [f.strip() for f in files.split(",")]
            if any(not f or f.startswith("/") or ".." in f.split("/") for f in files):
                usage(f"{where}: {name} has a bad license file path")
        globs = [] if covers == "-" else [g.strip() for g in covers.split(",")]
        if any(not g for g in globs):
            usage(f"{where}: {name} has an empty glob")
        components.append((name, spdx, files, [glob_regex(g) for g in globs]))
    if not components:
        usage(f"{path}: no components")
    return components


def main():
    args = sys.argv[1:]
    manifest = args.pop(0)
    if "--manifest" in args:
        at = args.index("--manifest")
        if at + 1 >= len(args):
            usage("--manifest needs a file")
        manifest = args[at + 1]
        del args[at:at + 2]
    if len(args) != 1:
        usage("one <Libraries> folder")
    root = args[0]
    if not os.path.isdir(root):
        usage(f"no folder {root}")
    components = load(manifest)
    problems = []

    licenses = os.path.join(root, LICENSES)
    if not os.path.isdir(licenses):
        problems.append(f"no licenses folder: {LICENSES}")
    texts = 0
    for name, spdx, files, _ in components:
        if not files:
            print(f"note: {name} has no license text ({spdx})")
        for file in files:
            path = os.path.join(licenses, name, file)
            if os.path.islink(path) or not os.path.isfile(path):
                problems.append(f"missing license text: {name} {file}")
            elif os.path.getsize(path) == 0:
                problems.append(f"empty license text: {name} {file}")
            else:
                texts += 1

    notices = os.path.join(root, NOTICES)
    if not os.path.isfile(notices):
        problems.append(f"no NOTICES: {NOTICES}")
    else:
        rows = {line.split(" | ", 1)[0] for line in open(notices, encoding="utf-8", errors="replace")
                if " | " in line}
        for name, *_ in components:
            if name not in rows:
                problems.append(f"not in NOTICES: {name}")

    owned = {name: 0 for name, *_ in components}
    for folder, dirs, names in os.walk(root):
        dirs.sort()
        for entry in sorted(names):
            path = os.path.join(folder, entry)
            if os.path.islink(path) or not os.path.isfile(path):
                continue
            rel = os.path.relpath(path, root).replace(os.sep, "/")
            owner = next((name for name, _, _, globs in components if any(r.match(rel) for r in globs)), None)
            if owner is None:
                problems.append(f"uncovered: {rel}")
            else:
                owned[owner] += 1
    covered = sum(owned.values())
    # An entry shadowed by an earlier one, or a library no longer bundled.
    for name, _, _, globs in components:
        if globs and not owned[name]:
            print(f"note: {name} covers no file")

    for problem in problems:
        print(problem)
    print(f"licenses: {len(components)} components, {texts} license texts, {covered} files covered, "
          f"{len(problems)} problem(s)")
    sys.exit(1 if problems else 0)


main()
PY
