#!/bin/bash
# macho_facts.sh <Ano.app> <out-dir>: the facts of every Mach-O file in an app
# bundle, as text for the gate (Plan 3c-5, Task 4).
#
# The app-bundle gate reads a Mach-O file's name only (wine_tokens.py
# --skip-macho): Swift keeps code-only names such as WhiskyWineInstaller in its
# metadata (decision 6). What a Mach-O shows the Mac is judged instead, one
# text file per Mach-O in <out-dir>, named by its path in the bundle with "/"
# as "__" (Contents__MacOS__Ano.txt):
#   - codesign -dv: the Identifier line
#   - codesign -d --entitlements - --xml: the entitlements (the same as
#     --entitlements :-, which codesign now calls deprecated)
#   - otool -L: the libraries it loads
#   - otool -l: its LC_RPATH and LC_ID_DYLIB entries
#   - its embedded __TEXT,__info_plist
# for every architecture of a fat file. Paths inside the bundle are written
# relative to it, so no fact carries where the bundle was unpacked.
#
# Exit 0: the facts are written. Exit 2: a harness error, such as no Mach-O
# in the bundle, a fact that could not be read, or a main executable whose
# identifier, entitlements or libraries are missing from its facts.
set -Eeuo pipefail
trap 'echo "::error::macho_facts.sh: line $LINENO: exit $?"; exit 2' ERR
harness() { echo "::error::macho_facts.sh: $*"; exit 2; }
[ $# -eq 2 ] || harness "usage: macho_facts.sh <Ano.app> <out-dir>"
APP=$(cd "$1" 2> /dev/null && pwd -P) || harness "no folder $1"
[ -f "$APP/Contents/Info.plist" ] || harness "$APP has no Contents/Info.plist"
mkdir -p "$2"
OUT=$(cd "$2" && pwd -P)
[ -z "$(ls -A "$OUT")" ] || harness "$OUT is not empty"
for tool in codesign otool python3 perl od; do
  command -v "$tool" > /dev/null || harness "no $tool on PATH"
done
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# The embedded __TEXT,__info_plist of each architecture, or "(none)".
info_plist() {  # file
  python3 -I - "$1" << 'PY'
import struct
import sys

with open(sys.argv[1], "rb") as fh:
    data = fh.read()
FAT = {b"\xca\xfe\xba\xbe": ">", b"\xbe\xba\xfe\xca": "<"}
THIN = {b"\xcf\xfa\xed\xfe": ("<", True), b"\xfe\xed\xfa\xcf": (">", True),
        b"\xce\xfa\xed\xfe": ("<", False), b"\xfe\xed\xfa\xce": (">", False)}


def slices():
    order = FAT.get(data[:4])
    if order is None:
        yield 0
        return
    (count,) = struct.unpack(order + "I", data[4:8])
    for i in range(count):
        yield struct.unpack(order + "iiIII", data[8 + 20 * i:28 + 20 * i])[2]


def section(base):
    order, is64 = THIN[data[base:base + 4]]
    (ncmds,) = struct.unpack(order + "I", data[base + 16:base + 20])
    at = base + (32 if is64 else 28)
    for _ in range(ncmds):
        cmd, size = struct.unpack(order + "II", data[at:at + 8])
        if cmd in (0x19, 0x1):  # LC_SEGMENT_64, LC_SEGMENT
            nsects_at, first, width = (at + 64, at + 72, 80) if cmd == 0x19 else (at + 48, at + 56, 68)
            (nsects,) = struct.unpack(order + "I", data[nsects_at:nsects_at + 4])
            for i in range(nsects):
                sect = data[first + i * width:first + (i + 1) * width]
                if sect[:16].rstrip(b"\0") == b"__info_plist" and sect[16:32].rstrip(b"\0") == b"__TEXT":
                    if is64:
                        length, offset = struct.unpack(order + "QI", sect[40:52])
                    else:
                        length, offset = struct.unpack(order + "II", sect[36:44])
                    return data[base + offset:base + offset + length]
        at += size
    return None


for n, base in enumerate(slices()):
    if data[base:base + 4] not in THIN:
        print(f"(architecture {n}: not a Mach-O)")
        continue
    plist = section(base)
    if plist is None:
        print(f"(architecture {n}: none)")
    else:
        sys.stdout.write(plist.decode("utf-8", "replace").rstrip("\0") + "\n")
PY
}

# One Mach-O's facts on stdout; 1 when a fact could not be read. An unsigned
# file has no identifier or entitlements: that is a fact, written as such.
facts_of() {  # file, its path in the bundle
  local f=$1 rel=$2 sig
  echo "# $rel"
  echo
  echo "## codesign -dv: Identifier"
  sig=$(codesign -dv "$f" 2>&1) || true
  grep '^Identifier=' <<< "$sig" || echo "(none: $(head -n 1 <<< "$sig"))"
  echo
  echo "## codesign -d --entitlements - --xml"
  codesign -d --entitlements - --xml "$f" 2> /dev/null || true
  echo
  echo
  echo "## otool -L"
  otool -arch all -L "$f" || return 1
  echo
  echo "## otool -l: LC_RPATH and LC_ID_DYLIB"
  otool -arch all -l "$f" > "$TMP/load-commands" || return 1
  awk '
    /^[^ ].*\(architecture / { print; next }
    $1 == "cmd" { cmd = $2; want = (cmd == "LC_RPATH" || cmd == "LC_ID_DYLIB"); next }
    want && ($1 == "path" || $1 == "name") { sub(/^ +/, ""); print cmd " " $0; want = 0 }' "$TMP/load-commands"
  echo
  echo "## __TEXT,__info_plist"
  info_plist "$f" || return 1
}

# Inside the bundle, a path is written relative to it.
export MACHO_FACTS_APP="$APP/"
n=0
while IFS= read -r -d '' f; do
  magic=$(head -c 4 "$f" | od -An -tx1 | tr -d ' \n')
  case $magic in
    feedface | cefaedfe | feedfacf | cffaedfe | cafebabe | bebafeca) ;;
    *) continue ;;
  esac
  rel=${f#"$APP"/}
  facts_of "$f" "$rel" > "$TMP/facts" 2> "$TMP/facts.err" \
    || harness "could not read the facts of $rel: $(head -c 400 "$TMP/facts.err")"
  perl -pe 's/\Q$ENV{MACHO_FACTS_APP}\E//g' "$TMP/facts" > "$OUT/${rel//\//__}.txt"
  n=$((n + 1))
done < <(find "$APP" -type f -print0 | LC_ALL=C sort -z)

[ "$n" -gt 0 ] || harness "no Mach-O file in $APP"
# The main executable proves each kind of fact was read: it is signed with an
# identifier, has the app's entitlements and loads libSystem.
main_exe=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist") \
  || harness "Contents/Info.plist has no CFBundleExecutable"
main="$OUT/Contents__MacOS__$main_exe.txt"
[ -f "$main" ] || harness "no facts for the main executable Contents/MacOS/$main_exe"
grep -q '^Identifier=' "$main" || harness "codesign gave no Identifier for Contents/MacOS/$main_exe"
grep -q '<key>' "$main" || harness "codesign gave no entitlements for Contents/MacOS/$main_exe"
grep -q 'libSystem' "$main" || harness "otool -L listed no libSystem for Contents/MacOS/$main_exe"
echo "macho_facts.sh: $n Mach-O files in $(basename "$APP"); facts in $OUT"
