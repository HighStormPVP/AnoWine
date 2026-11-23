#!/bin/bash
# Tests clean-rosetta-cache.sh against a fake Rosetta cache: the three files
# named after the old runtime's modules are listed and removed, Ano's own file
# and other files stay, and a symlink is never followed. The fake root has a
# space in its name. Runs on Linux (AnoWine Hygiene) and macOS.
# Usage: scripts/anowine/test-clean-rosetta-cache.sh [repo-root]
set -euo pipefail
ROOT=$(cd "${1:-$(dirname "$0")/../..}" && pwd)
script=$ROOT/scripts/anowine/clean-rosetta-cache.sh
tmp=$(mktemp -d)
trap 'chmod -R u+rwx "$tmp" 2> /dev/null; rm -rf "$tmp"' EXIT

root="$tmp/fake root"
oah="$root/var/db/oah"
cache="$oah/u1/h1"
mkdir -p "$cache" "$tmp/outside"
for name in winemac.so.aot WINEBUS.SO.aot anowine.aot ano-core.aot notes.txt; do
  printf 'x' > "$cache/$name"
done
printf 'keep' > "$tmp/outside/wine-target.aot"
ln -s "$tmp/outside/wine-target.aot" "$cache/link-wine.aot"
expected=$(printf '%s\n' "$cache/WINEBUS.SO.aot" "$cache/anowine.aot" "$cache/winemac.so.aot" | LC_ALL=C sort)

fail=0
ok() { echo "ok: $1"; }
bad() {
  echo "FAIL: $1 (exit $code)"
  printf '%s\n' "$out" | sed 's/^/    /'
  fail=1
}
run() {  # run <args...>: sets code and out (stdout and stderr)
  code=0
  out=$(bash "$script" "$@" 2>&1) || code=$?
  # What the script says, without the paths it lists, for case 7.
  printf '%s\n' "$out" | awk -v p="$root/" 'index($0, p) != 1' >> "$tmp/said"
}
listed() {  # the lines of $out that are paths in the fake root
  printf '%s\n' "$out" | awk -v p="$root/" 'index($0, p) == 1' | LC_ALL=C sort
}
all_there() {
  local name
  for name in winemac.so.aot WINEBUS.SO.aot anowine.aot ano-core.aot notes.txt; do
    [ -f "$cache/$name" ] || return 1
  done
  [ -L "$cache/link-wine.aot" ]
}

# 1. Without --delete it lists exactly the 3 and deletes nothing.
run --root "$root"
if [ "$code" = 0 ] && [ "$(listed)" = "$expected" ] && grep -q 'Found 3 files' <<< "$out" && all_there; then
  ok "a listing run lists exactly the 3 and deletes nothing"
else
  bad "a listing run lists exactly the 3 and deletes nothing"
fi

# 2. --delete without --root needs root rights.
if [ "$(id -u)" = 0 ]; then
  echo "skipped: running as root, so --delete without --root cannot be refused here"
else
  run --delete
  if [ "$code" = 2 ] && grep -q 'run with sudo' <<< "$out"; then
    ok "--delete without --root as non-root exits 2 (run with sudo)"
  else
    bad "--delete without --root as non-root exits 2 (run with sudo)"
  fi
fi

# 3. A cache folder it cannot read is reported, with sudo as the way out.
if [ "$(id -u)" = 0 ]; then
  echo "skipped: running as root, so every folder is readable"
else
  chmod 000 "$oah"
  run --root "$root"
  chmod 755 "$oah"
  if [ "$code" = 2 ] && grep -q 'run with sudo' <<< "$out"; then
    ok "an unreadable cache folder exits 2 (run with sudo)"
  else
    bad "an unreadable cache folder exits 2 (run with sudo)"
  fi
fi

# 4. --delete --root removes the 3 and keeps the rest; the link is not followed.
run --delete --root "$root"
gone=1
for name in winemac.so.aot WINEBUS.SO.aot anowine.aot; do
  if [ -e "$cache/$name" ]; then gone=0; fi
done
if [ "$code" = 0 ] && [ "$gone" = 1 ] && grep -q 'Removed 3 files' <<< "$out"; then
  ok "--delete --root removes the 3"
else
  bad "--delete --root removes the 3"
fi
if [ -f "$cache/ano-core.aot" ] && [ -f "$cache/notes.txt" ] && [ -L "$cache/link-wine.aot" ]; then
  ok "ano-core.aot, notes.txt and the symlink (not a regular file) are kept"
else
  bad "ano-core.aot, notes.txt and the symlink (not a regular file) are kept"
fi
if [ "$(cat "$tmp/outside/wine-target.aot" 2> /dev/null)" = keep ]; then
  ok "the symlink's target survives"
else
  bad "the symlink's target survives"
fi

# 5. With none left, it says so and exits 0.
run --root "$root"
if [ "$code" = 0 ] && grep -q 'nothing to clean' <<< "$out" && [ -z "$(listed)" ]; then
  ok "with none left it exits 0 with nothing to clean"
else
  bad "with none left it exits 0 with nothing to clean"
fi

# 6. No cache folder at all: nothing to clean.
mkdir -p "$tmp/no cache"
run --root "$tmp/no cache"
if [ "$code" = 0 ] && grep -q 'no Rosetta cache' <<< "$out" && grep -q 'nothing to clean' <<< "$out"; then
  ok "a missing cache folder exits 0 with nothing to clean"
else
  bad "a missing cache folder exits 0 with nothing to clean"
fi

# 7. Nothing the script says names the old runtime, only the paths it lists
# may. The repo and temp folders are taken out first (the repo is AnoWine).
run --help
run --no-such-option
said=$(cat "$tmp/said")
said=${said//"$ROOT"/REPO}
said=${said//"$tmp"/TMP}
code=-
out=$(grep -i 'wine' <<< "$said" || true)
if [ -f "$script" ] && [ -z "$out" ]; then
  ok "its messages never say the old name"
else
  bad "its messages never say the old name"
fi

exit "$fail"
