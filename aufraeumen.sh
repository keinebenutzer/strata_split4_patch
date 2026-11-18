#!/usr/bin/env bash
# aufraeumen.sh -- aufraeumen und dabei beweisen, dass der Patch folgenlos ist.
#
#   ./aufraeumen.sh --baum /pfad/zum/strata              # prüfen und melden, nichts löschen
#   ./aufraeumen.sh --baum ... --zyklus                  # Wegwerf-Worktree: apply -> revert -> Baum wieder sauber
#   ./aufraeumen.sh --baum ... --loeschen                # zusaetzlich: Build-Ordner dieses Skripts und Log-Reste weg
#   ./aufraeumen.sh --baum ... --wenn-angewandt-zurueck  # Patch zuruecknehmen, wenn er im Baum liegt
#
# Gelöscht wird nur, was diese Skripte hinterlassen haben (build-split4*, *.configure.log, *.build.log,
# Wegwerf-Worktrees unter .hermes-cache/). Binaries, Konfiguration und der Baum selbst bleiben in Ruhe.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PATCH="$HERE/split4/strata_split4_all.patch"
BASE_FILE="$HERE/split4/BASE.txt"
TREE="${STRATA_DIR:-$PWD}"
CYCLE=0
DELETE=0
REVERT_IF=0

while [ $# -gt 0 ]; do
  case "$1" in
    --baum) TREE="$2"; shift 2 ;;
    --zyklus) CYCLE=1; shift ;;
    --loeschen) DELETE=1; shift ;;
    --wenn-angewandt-zurueck) REVERT_IF=1; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "Unbekannte Option: $1 (helft: --help)"; exit 2 ;;
  esac
done

say() { printf '%s\n' "$*"; }
[ -f "$PATCH" ] || { say "Patch fehlt: $PATCH"; exit 2; }
[ -f "$TREE/src/split/CMakeLists.txt" ] || { say "Kein Strata-Baum in $TREE"; exit 2; }
cd "$TREE"

say "Baum:  $TREE"
say "Stand: $(git rev-parse --short HEAD)   Patch-Basis: $(cat "$BASE_FILE" 2>/dev/null || echo '?')"

# ---- 1) Was der Patch inhaltlich tut (aus dem Patch selbst gezählt, nicht aus dem Baum) ----
say ""
say "== Der Patch =="
FILES="$(grep -c '^diff --git' "$PATCH")"
SAYS="$(grep -Ec '^\+' "$PATCH")"
SAYS="$((${SAYS:-0} - FILES))"      # die +++-Dateizeilen nicht als Inhalt zaehlen
say "  Dateien: $FILES   zugefügte Zeilen: ${SAYS:-0}"
grep '^diff --git' "$PATCH" | sed -E 's|^diff --git a/[^ ]+ b/|    |'

# ---- 2) Liegt der Patch im Baum? ----
say ""
say "== Zustand im Baum =="
FWD=0; REV=0
git apply --check "$PATCH" >/dev/null 2>&1 && FWD=1
git apply --check -R "$PATCH" >/dev/null 2>&1 && REV=1
if [ "$REV" = 1 ] && [ "$FWD" = 0 ]; then
  say "  angewandt (zuruecknehmbar)."
  [ "$REVERT_IF" = 1 ] && { git apply -R "$PATCH" && say "  zurueckgenommen."; }
elif [ "$FWD" = 1 ] && [ "$REV" = 0 ]; then
  say "  nicht angewandt (sauber anwendbar)."
elif [ "$FWD" = 1 ] && [ "$REV" = 1 ]; then
  say "  unentschieden: vorwaerts UND rueckwaerts moeglich -- es liegt mehr als dieser Patch dazwischen."
else
  say "  passt nicht auf diesen Stand (weder vorwaerts noch rueckwaerts). Nichts angefasst."
fi
DIRTY="$(git status --short | wc -l)"
say "  geaenderte Dateien im Baum: $DIRTY"
[ "$DIRTY" != "0" ] && git status --short | sed 's/^/    /'

# ---- 3) Zyklustest auf einer Wegwerf-Worktree ----
if [ "$CYCLE" = 1 ]; then
  say ""
  say "== Zyklus auf Wegwerf-Worktree (nichts im echten Baum) =="
  BASE="$(cat "$BASE_FILE" 2>/dev/null || true)"
  [ -n "$BASE" ] || { say "  keine Basis in split4/BASE.txt -- Zyklus übersprungen."; }
  if [ -n "$BASE" ]; then
    WT="$TREE/.split4_aufraeumen_wt"
    git worktree remove --force "$WT" 2>/dev/null || true
    rm -rf "$WT"
    if git worktree add --detach "$WT" "$BASE" >/dev/null 2>&1; then
      ( cd "$WT"
        if git apply "$PATCH" 2>/dev/null; then
          A="$(git status --short | wc -l)"
          if git apply -R "$PATCH" 2>/dev/null && [ "$(git status --short | wc -l)" = "0" ]; then
            say "  apply ($A Dateien) -> revert -> Baum sauber: der Patch ist folgenlos."
          else
            say "  revert machte den Baum NICHT sauber -- bitte melden."
          fi
        else
          say "  apply ging auf der Basis nicht -- Patch oder Basis ist nicht mehr aktuell."
        fi )
      git worktree remove --force "$WT" 2>/dev/null || rm -rf "$WT"
      git worktree prune 2>/dev/null || true
    else
      say "  Worktree lies sich nicht anlegen (Stand $BASE fehlt im Repo?)."
    fi
  fi
fi

# ---- 4) Aufräumen: nur eigene Reste ----
say ""
say "== Aufräumen =="
LEFT=()
for p in "$TREE"/build-split4 "$TREE"/build-split4.configure.log "$TREE"/build-split4.build.log "$TREE"/.split4_aufraeumen_wt; do
  [ -e "$p" ] && LEFT+=("$p")
done
if [ "${#LEFT[@]}" = "0" ]; then
  say "  nichts von diesem Skript hinterlassen."
else
  for p in "${LEFT[@]}"; do say "  Rest: $p"; done
  if [ "$DELETE" = 1 ]; then
    for p in "${LEFT[@]}"; do rm -rf "$p" && say "    entfernt: $p"; done
  else
    say "  (nur gemeldet -- --loeschen entfernt sie)"
  fi
fi
say ""
say "Fertig."
