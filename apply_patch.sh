#!/usr/bin/env bash
# apply_patch.sh [check|apply|revert] [verzeichnis]
# Den einen split4-Grosspatch auf/ vom Arbeitsbaum. Vor update.sh: revert; danach: apply.
# Wer es bequemer will: install.sh fragt die Karten, prueft, wendet an, baut und beweist.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
MODE="${1:-check}"
DIR="${2:-.}"
PATCH="$HERE/split4/strata_split4_all.patch"
[ -f "$PATCH" ] || { echo "Patch fehlt: $PATCH"; exit 2; }
cd "$DIR"
case "$MODE" in
  check)  git apply --check "$PATCH" && echo "konfliktfrei auf diesem Stand ($(git rev-parse --short HEAD), Patch-Basis $(cat "$HERE/split4/BASE.txt" 2>/dev/null || echo '?'))." ;;
  apply)  git apply "$PATCH" && echo "angewandt (nicht committet)." ;;
  revert) git apply -R "$PATCH" && echo "zurueckgenommen." ;;
  *) echo "Modus: check | apply | revert"; exit 2 ;;
esac
