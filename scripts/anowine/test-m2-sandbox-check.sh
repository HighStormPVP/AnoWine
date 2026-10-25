#!/bin/bash
# Runs m2-sandbox-check.sh non-interactively on a macOS runner with stub Wine
# programs and scripted answers. Proves the sandbox profile is accepted by
# sandbox-exec and that each round's exit status and log reach the results,
# so a launch failure can't be mistaken for "the sandbox breaks rendering".
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/anowine-m2-test-XXXXXX")"
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/bin" "$T/prefix/drive_c/Program Files (x86)/Steam"
: > "$T/prefix/drive_c/Program Files (x86)/Steam/steam.exe"
cat > "$T/bin/anowine" <<'EOF'
#!/bin/bash
echo "stub loader started: $(basename "$1")"
exit 0
EOF
cat > "$T/bin/anowine-server" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$T/bin/anowine" "$T/bin/anowine-server"

# Per round: Enter, then y (window), y (store), n (game).
OUT="$(printf '\ny\ny\nn\n\ny\ny\nn\n' | env PATH="$T/bin:$PATH" WINEPREFIX="$T/prefix" \
  WINESERVER="$T/bin/anowine-server" bash "$HERE/m2-sandbox-check.sh" 2>&1)"
rc=$?
echo "$OUT"
echo "== script exit: $rc"

status=0
check() { if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1"; status=1; fi; }
check "script exits 0" '[ "$rc" -eq 0 ]'
check "normal round answers and exit status recorded" \
  'grep -q "^normal: steam_window=yes store_page=yes game=no launch_exit=0$" <<<"$OUT"'
check "sandboxed round ran inside sandbox-exec and exited 0" \
  'grep -q "^sandboxed: steam_window=yes store_page=yes game=no launch_exit=0$" <<<"$OUT"'
check "each round's launch log is included" \
  '[ "$(grep -c "stub loader started: steam.exe" <<<"$OUT")" -ge 2 ]'
exit "$status"
