#!/bin/bash
# Fails if a script has CRLF line endings or an AnoWine/spike shell script
# is not executable in git. Usage: scripts/anowine/check-hygiene.sh [repo-root]
set -euo pipefail
ROOT="$(cd "${1:-$(dirname "$0")/../..}" && pwd)"
cd "$ROOT"
status=0
while IFS= read -r f; do
  # Check the committed (index) content, which is what macOS checks out.
  if [ "$(git cat-file -p ":$f" | tr -cd '\r' | wc -c)" -gt 0 ]; then
    echo "::error file=$f::CRLF line endings"
    status=1
  fi
done < <(git ls-files -- '*.sh' '*.c' '*.h' '*.sb' '*.py')
while read -r mode _ _ f; do
  if [ "$mode" != "100755" ]; then
    echo "::error file=$f::shell script is not executable (git mode $mode)"
    status=1
  fi
done < <(git ls-files -s -- 'scripts/anowine/*.sh' 'scripts/anowine-*.sh' 'spikes/*.sh' 'spikes/**/*.sh')
[ "$status" -eq 0 ] && echo "hygiene OK"
exit "$status"
