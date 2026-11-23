#!/bin/bash
# Lists, and with --delete removes, Rosetta's cached translations of the old
# runtime's files. Rosetta keeps a translation of every Intel program and
# library it has run in /var/db/oah, named after the file plus ".aot". Ano 6
# to 8 shipped a runtime whose files had Wine's names (winemac.so.aot,
# winebus.so.aot, anowine.aot, ...), so their translations still carry them.
# The same files of other Wine apps (Whisky, CrossOver) match too. Rosetta
# makes a translation again for any program that still needs it, so removing
# them is safe. Only root can read or change /var/db/oah, so on a Mac run:
#   sudo bash ~/Downloads/clean-rosetta-cache.sh            (look, changes nothing)
#   sudo bash ~/Downloads/clean-rosetta-cache.sh --delete   (remove them)
# --root DIR looks in DIR/var/db/oah instead (the tests use a fake tree).
# Written for macOS's bash 3.2 and BSD find; GNU find works too. It never
# follows a symlink (find -P) and only touches regular files.
set -euo pipefail

usage() {
  echo "Usage: clean-rosetta-cache.sh [--delete] [--root DIR]"
  echo "Lists Rosetta's cached translations of the old runtime's files in"
  echo "/var/db/oah (or DIR/var/db/oah); --delete removes them. Needs sudo."
}
files() { if [ "$1" = 1 ]; then echo "1 file"; else echo "$1 files"; fi; }

delete=0
root=/
root_given=0
while [ $# -gt 0 ]; do
  case $1 in
    --delete) delete=1 ;;
    --root)
      if [ $# -lt 2 ] || [ -z "$2" ]; then
        usage >&2
        exit 1
      fi
      root=$2
      root_given=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

# The command to run again, as typed, for the hints below.
again="sudo bash $(printf '%q' "$0")"
if [ "$root_given" = 1 ]; then again="$again --root $(printf '%q' "$root")"; fi
if [ "$(id -u)" = 0 ]; then is_root=1; else is_root=0; fi

if [ "$delete" = 1 ] && [ "$root_given" = 0 ] && [ "$is_root" = 0 ]; then
  echo "Removing these files needs administrator rights: run with sudo:" >&2
  echo "  $again --delete" >&2
  exit 2
fi

dir=${root%/}/var/db/oah
if [ ! -e "$dir" ] && [ ! -L "$dir" ]; then
  echo "There is no Rosetta cache at $dir: nothing to clean."
  exit 0
fi
if [ ! -d "$dir" ]; then
  echo "$dir is not a folder." >&2
  exit 1
fi
if [ ! -r "$dir" ] || [ ! -x "$dir" ]; then
  echo "Cannot read $dir: only an administrator can, so run with sudo:" >&2
  if [ "$delete" = 1 ]; then echo "  $again --delete" >&2; else echo "  $again" >&2; fi
  exit 2
fi

status=0
unread() {  # find could not read some folders: say so, and how to fix it
  echo "Some folders in $dir could not be read, so this may not be all of them." >&2
  if [ "$is_root" = 0 ]; then
    echo "Look again and run with sudo: $again" >&2
    status=2
  else
    status=1
  fi
}
# Regular files only, never through a symlink. The pattern is the old
# runtime's name; Ano's own files (ano-core.aot, ...) do not match it.
find_old() { find -P "$dir" -type f -iname '*wine*.aot' -print; }

found=$(find_old | LC_ALL=C sort) || unread
if [ -z "$found" ]; then
  echo "No cached translations of the old runtime's files in $dir: nothing to clean."
  exit "$status"
fi
count=$(printf '%s\n' "$found" | wc -l | tr -d ' ')
echo "Rosetta's cached translations of the old runtime's files in $dir:"
printf '%s\n' "$found"
echo "Found $(files "$count")."

if [ "$delete" = 0 ]; then
  echo "To remove them: $again --delete"
  echo "Rosetta makes them again for any program that still needs them."
  exit "$status"
fi

find -P "$dir" -type f -iname '*wine*.aot' -exec rm -f -- {} + || status=1
removed=0
while IFS= read -r path; do
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then removed=$((removed + 1)); fi
done <<< "$found"
left=$(find_old | LC_ALL=C sort) || unread
if [ -n "$left" ]; then
  echo "Could not remove:" >&2
  printf '%s\n' "$left" >&2
  status=1
fi
echo "Removed $(files "$removed"). Rosetta makes them again for any program that still needs them."
exit "$status"
