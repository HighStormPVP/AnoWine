#!/usr/bin/env python3
"""Collect each component's license files (licenses.txt), word for word from its source.

Usage: collect_licenses.py --manifest FILE --out DIR --cache DIR --nixpkgs REV
                           --winecx URL@COMMIT [--pin URL=git:COMMIT | URL=tar:SHA256]...
                           [--facts FILE.tsv]

Writes DIR/<component>/<path> for each component whose source is:
  winecx            the file at COMMIT of the GitHub repository URL (read from
                    git, so before Ano's rename);
  url:<URL>         a URL given with --pin: a GitHub repository (the file at the
                    commit) or a tarball (checked against its SHA-256; paths are
                    inside its single top folder, as nix unpacks it);
  nix:<attribute>   the x86_64-darwin attribute of nixpkgs at REV: the line's
                    version must equal the attribute's, and its spdx must equal
                    meta.license (spdxId; a list joined with " AND "; without an
                    spdxId, LicenseRef-nixpkgs-<shortName>); the files come from
                    the attribute's .src.
recipe has no license files and payload: files come from build-payloads.sh.

Every mismatch is printed, with what nixpkgs says and the license-like files the
source has, then exit 1. --facts writes those facts for every nix component.
Exit 2 on bad arguments or a malformed manifest.
"""
import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import time
import urllib.request
import zipfile

LIKE_LICENSE = re.compile(r"(?i)(licen[cs]e|copying|copyright|notice|authors|patents|legal)")
NIX_EXPR = r"""
let
  flake = builtins.getFlake "github:NixOS/nixpkgs/@REV@";
  lib = flake.lib;
  get = system: path:
    let found = builtins.tryEval (lib.attrByPath (lib.splitString "." path) null flake.legacyPackages.${system});
    in if found.success then found.value else null;
  srcOf = p:
    let found = builtins.tryEval (if p != null && p ? src then p.src.outPath else null);
    in if found.success then found.value else null;
  license = l:
    if builtins.isList l then map license l
    else if builtins.isAttrs l then (l.spdxId or ("LicenseRef-nixpkgs-" + (l.shortName or "unknown")))
    else toString l;
  facts = path:
    let p = get "x86_64-darwin" path; q = get "x86_64-linux" path;
    in if p == null then null else {
      version = p.version or null;
      license = license (p.meta.license or [ ]);
      src = srcOf p;
      linuxSrc = srcOf q;
    };
in builtins.listToAttrs (map (a: { name = a; value = facts a; }) (builtins.fromJSON ''@ATTRS@''))
"""


def bad(message):
    print(f"collect_licenses.py: {message}", file=sys.stderr)
    sys.exit(2)


def manifest(path):
    """[(name, version, spdx, source, [files])] from licenses.txt."""
    rows = []
    for number, line in enumerate(open(path, encoding="utf-8").read().splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        fields = [field.strip() for field in line.split("\t")]
        if len(fields) != 7:
            bad(f"{path}:{number}: want 7 fields, got {len(fields)}")
        name, version, spdx, source, files = fields[:5]
        rows.append((name, version, spdx, source, [] if files == "-" else files.split(",")))
    return rows


def download(url, dest, sha256=None):
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    for attempt in range(8):
        try:
            with urllib.request.urlopen(url, timeout=60) as response, open(dest, "wb") as out:
                shutil.copyfileobj(response, out)
            break
        except Exception as error:  # a dropped transfer is retried, like build-engine.sh's fetch
            if attempt == 7:
                raise RuntimeError(f"download failed: {url}: {error}")
            time.sleep(5)
    if sha256:
        got = hashlib.sha256(open(dest, "rb").read()).hexdigest()
        if got != sha256:
            os.remove(dest)
            raise RuntimeError(f"SHA-256 of {url} is {got}, expected {sha256}")
    if os.path.getsize(dest) == 0:
        raise RuntimeError(f"empty: {url}")


def raw_github(repo_url, commit, path):
    match = re.match(r"^https://github\.com/([^/]+/[^/]+?)(?:\.git)?/?$", repo_url)
    if not match:
        raise RuntimeError(f"not a GitHub repository: {repo_url}")
    return f"https://raw.githubusercontent.com/{match.group(1)}/{commit}/{path}"


class Source:
    """A source tree: a folder, or an archive whose paths are inside its single top folder.

    A license file that is a link (COPYING -> LICENSES/LGPL-2.1-or-later.txt) is
    read through the link, as in a checkout. Archives Python cannot open (lzip,
    zstd) go through tar(1)."""

    def __init__(self, path):
        self.path = path
        self.members = None
        self.kind = "dir"
        if os.path.isdir(path):
            return
        if zipfile.is_zipfile(path):
            self.kind = "zip"
            names = zipfile.ZipFile(path).namelist()
        else:
            try:
                self.archive = tarfile.open(path)
                self.kind = "tarfile"
                names = self.archive.getnames()
            except (tarfile.TarError, OSError):
                self.kind = "tar"
                listing = subprocess.run(["tar", "-tf", path], capture_output=True, text=True, errors="replace")
                if listing.returncode:
                    raise RuntimeError(f"cannot list {path}: {listing.stderr.strip()}")
                names = listing.stdout.splitlines()
        cleaned = []
        for name in names:
            short = name
            while short.startswith("./"):
                short = short[2:]
            if short:
                cleaned.append((short, name))
        tops = {short.split("/", 1)[0] for short, _ in cleaned}
        single = len(tops) == 1 and all("/" in short or short == next(iter(tops)) for short, _ in cleaned)
        self.members = {}
        for short, name in cleaned:
            if single:
                short = short.split("/", 1)[1] if "/" in short else ""
            if short and not short.endswith("/"):
                self.members.setdefault(short, name)

    def names(self):
        if self.members is not None:
            return list(self.members)
        found = []
        for folder, dirs, files in os.walk(self.path):
            dirs[:] = [d for d in dirs if d != ".git"]
            rel = os.path.relpath(folder, self.path)
            for name in files:
                found.append(name if rel == "." else f"{rel}/{name}".replace(os.sep, "/"))
        return found

    def like_license(self):
        return sorted(n for n in self.names() if n.count("/") <= 1 and LIKE_LICENSE.search(n.rsplit("/", 1)[-1]))

    def copy(self, rel, dest):
        """True when rel is a regular, non-empty file of the source, now copied to dest."""
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        if self.members is None:
            path = os.path.join(self.path, rel)
            if not os.path.isfile(path):
                return False
            shutil.copyfile(path, dest)
        else:
            if rel not in self.members:
                return False
            member = self.members[rel]
            if self.kind == "zip":
                with zipfile.ZipFile(self.path) as archive, open(dest, "wb") as out:
                    out.write(archive.read(member))
            elif self.kind == "tarfile":
                try:
                    data = self.archive.extractfile(member)  # follows symbolic and hard links
                except KeyError:
                    return False
                if data is None:
                    return False
                with open(dest, "wb") as out:
                    shutil.copyfileobj(data, out)
            else:
                with open(dest, "wb") as out:
                    if subprocess.run(["tar", "-xOf", self.path, member], stdout=out).returncode:
                        return False
        return os.path.getsize(dest) > 0


def spdx_of(license):
    if isinstance(license, list):
        parts = [spdx_of(item) for item in license]
        return " AND ".join(part for part in parts if part)
    return license or ""


def nix_components(rows, rev, out, problems, facts_path):
    if not rows:
        return
    if not shutil.which("nix"):
        problems.append("nix: the nixpkgs libraries' sources need nix")
        return
    attrs = sorted({source[len("nix:"):] for _, _, _, source, _ in rows})
    expr = NIX_EXPR.replace("@REV@", rev).replace("@ATTRS@", json.dumps(attrs))
    result = subprocess.run(["nix", "eval", "--json", "--impure", "--expr", expr], capture_output=True, text=True)
    if result.returncode:
        problems.append(f"nix eval failed: {result.stderr.strip()[-3000:]}")
        return
    facts = json.loads(result.stdout)
    host_linux = platform.system() == "Linux"
    flake = f"github:NixOS/nixpkgs/{rev}"
    wanted = {}
    for name, version, spdx, source, files in rows:
        attr = source[len("nix:"):]
        fact = facts.get(attr)
        if fact is None:
            problems.append(f"{name} (nix:{attr}): no such x86_64-darwin attribute in nixpkgs {rev}")
            continue
        if not fact.get("src"):
            problems.append(f"{name} (nix:{attr}): the attribute has no src")
            continue
        system = "x86_64-linux" if host_linux and fact.get("linuxSrc") == fact["src"] else "x86_64-darwin"
        wanted[name] = (attr, f"{flake}#legacyPackages.{system}.{attr}.src", fact)
    installables = sorted({installable for _, installable, _ in wanted.values()})
    built = subprocess.run(["nix", "build", "--no-link", "--print-out-paths", *installables],
                           capture_output=True, text=True)
    if built.returncode:
        for installable in installables:
            one = subprocess.run(["nix", "build", "--no-link", "--print-out-paths", installable],
                                 capture_output=True, text=True)
            if one.returncode:
                problems.append(f"nix build {installable} failed: {one.stderr.strip()[-1500:]}")
    lines = []
    for name, version, spdx, source, files in rows:
        if name not in wanted:
            continue
        attr, _, fact = wanted[name]
        # No meta.license (the xorg libraries): nixpkgs asserts nothing.
        said = spdx_of(fact.get("license")) or "NOASSERTION"
        if not os.path.exists(fact["src"]):
            continue
        try:
            tree = Source(fact["src"])
        except RuntimeError as error:
            problems.append(f"{name} (nix:{attr}): {error}")
            continue
        candidates = ",".join(tree.like_license())
        lines.append("\t".join([name, attr, str(fact.get("version")), said, fact["src"], candidates]))
        if fact.get("version") != version:
            problems.append(f"{name} (nix:{attr}): nixpkgs' version is {fact.get('version')!r}, the manifest says "
                            f"{version!r}")
        if said != spdx:
            problems.append(f"{name} (nix:{attr}): meta.license is {said!r}, the manifest says {spdx!r}")
        for rel in files:
            if not tree.copy(rel, os.path.join(out, name, rel)):
                problems.append(f"{name} (nix:{attr}): no {rel} in {fact['src']}; license-like files there: "
                                f"{candidates or 'none'}")
    if facts_path:
        with open(facts_path, "w", encoding="utf-8") as fh:
            fh.write("component\tattribute\tversion\tlicense\tsrc\tlicense-like files\n")
            fh.write("".join(line + "\n" for line in lines))
    for line in lines:
        print("fact\t" + line)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--cache", required=True)
    parser.add_argument("--nixpkgs", required=True)
    parser.add_argument("--winecx", required=True, help="URL@COMMIT")
    parser.add_argument("--pin", action="append", default=[], help="URL=git:COMMIT or URL=tar:SHA256")
    parser.add_argument("--facts")
    args = parser.parse_args()
    winecx_url, _, winecx_commit = args.winecx.rpartition("@")
    if not winecx_url or not winecx_commit:
        bad("--winecx wants URL@COMMIT")
    pins = {}
    for pin in args.pin:
        url, _, value = pin.rpartition("=")
        kind, _, ref = value.partition(":")
        if not url or kind not in ("git", "tar") or not ref:
            bad(f"--pin wants URL=git:COMMIT or URL=tar:SHA256, not {pin!r}")
        pins[url] = (kind, ref)

    rows = manifest(args.manifest)
    problems, nix_rows = [], []
    os.makedirs(args.out, exist_ok=True)
    for name, version, spdx, source, files in rows:
        try:
            if source == "winecx":
                for rel in files:
                    download(raw_github(winecx_url, winecx_commit, rel), os.path.join(args.out, name, rel))
            elif source.startswith("url:"):
                url = source[len("url:"):]
                if url not in pins:
                    problems.append(f"{name}: {url} is not a URL pinned in build-engine.sh")
                    continue
                kind, ref = pins[url]
                if kind == "git":
                    for rel in files:
                        download(raw_github(url, ref, rel), os.path.join(args.out, name, rel))
                else:
                    archive = os.path.join(args.cache, f"{name}-{os.path.basename(url)}")
                    if not os.path.isfile(archive):
                        download(url, archive, ref)
                    tree = Source(archive)
                    for rel in files:
                        if not tree.copy(rel, os.path.join(args.out, name, rel)):
                            problems.append(f"{name}: no {rel} in {url}; license-like files there: "
                                            f"{','.join(tree.like_license()) or 'none'}")
            elif source.startswith("nix:"):
                nix_rows.append((name, version, spdx, source, files))
            elif source != "recipe" and not source.startswith("payload:"):
                problems.append(f"{name}: unknown source {source}")
        except RuntimeError as error:
            problems.append(f"{name}: {error}")
    nix_components(nix_rows, args.nixpkgs, args.out, problems, args.facts)

    for problem in problems:
        print(f"::error::{problem}")
    count = sum(len(names) for _, _, names in os.walk(args.out))
    print(f"collect_licenses: {len(rows)} components, {count} license files, {len(problems)} problem(s)")
    sys.exit(1 if problems else 0)


main()
