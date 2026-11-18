#!/usr/bin/env bash
# install.sh -- der eine Durchgang: pruefen, anwenden, bauen, beweisen.
#
#   ./install.sh --baum /pfad/zum/strata                 # alles automatisch, Architektur von den Karten
#   ./install.sh --baum ... --nur-pruefen                # nichts wird geaendert, nichts gebaut
#   ./install.sh --baum ... --arch 75 --karten "4"       # vier Turing-Karten, die hier niemand eingetragen hat
#   ./install.sh --baum ... --zurueck                    # Patch zuruecknehmen (vor update.sh)
#   ./install.sh --baum ... --selbsttest --testbau       # nach dem Bau die Kernel auf der Karte beweisen
#
# Die Architektur kommt von den Karten, nicht aus diesem Skript: nvidia-smi wird gefragt, und nur wenn alle
# Karten dieselbe Compute Capability haben, wird gebaut. Was die Architektur kann, entscheidet die Tabelle in
# src/split/src/arch_caps.hpp (Shared Memory je Karte, Tensor-Core-Pfade) -- nicht eine Zahl in dieser Datei.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PATCH="$HERE/split4/strata_split4_all.patch"
BASE_FILE="$HERE/split4/BASE.txt"
TREE="${STRATA_DIR:-$PWD}"
ARCH=""
CARDS=""
BUILD_DIR=""
MODE="install"
SELFTEST=0
TESTBUILD=0

while [ $# -gt 0 ]; do
  case "$1" in
    --baum)        TREE="$2"; shift 2 ;;
    --arch)        ARCH="$2"; shift 2 ;;
    --karten)      CARDS="$2"; shift 2 ;;
    --build-dir)   BUILD_DIR="$2"; shift 2 ;;
    --nur-pruefen) MODE="check"; shift ;;
    --ohne-bau)    MODE="apply"; shift ;;
    --zurueck)     MODE="revert"; shift ;;
    --selbsttest)  SELFTEST=1; shift ;;
    --testbau)     TESTBUILD=1; shift ;;
    -h|--help)     sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "Unbekannte Option: $1 (helft: --help)"; exit 2 ;;
  esac
done

say() { printf '%s\n' "$*"; }
fail() { printf '%s\n' "$*" >&2; exit 1; }

[ -f "$PATCH" ] || fail "Patch fehlt: $PATCH"
[ -f "$TREE/src/split/CMakeLists.txt" ] || fail "Kein Strata-Baum in $TREE (src/split/CMakeLists.txt fehlt). --baum angeben."
command -v git >/dev/null || fail "git fehlt."

cd "$TREE"
HEAD_NOW="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
BASE_WANT="$(cat "$BASE_FILE" 2>/dev/null || echo '')"
say "Baum:    $TREE"
say "Stand:   $HEAD_NOW   (der Patch ist geschnitten auf ${BASE_WANT:-?})"
if [ -n "$BASE_WANT" ] && [ "$HEAD_NOW" != "$BASE_WANT" ]; then
  say "Hinweis: anderer Stand als die Patch-Basis. git apply entscheidet, ob es trotzdem passt."
fi

# ---------------- Karten fragen ----------------
detect_cards() {
  command -v nvidia-smi >/dev/null || { say "nvidia-smi nicht gefunden -- Architektur muss mit --arch angegeben werden."; return; }
  local caps names
  caps="$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader,nounits 2>/dev/null | tr -d ' ' | sort -u)"
  names="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | sort -u)"
  local n; n="$(printf '%s\n' "$caps" | grep -c . || true)"
  [ "$n" = "0" ] && { say "nvidia-smi nennt keine Karten."; return; }
  GPU_COUNT="$n"
  say "Karten:  $n Stueck, Compute Capability: $(printf '%s ' $caps)"
  say "Namen:   $(printf '%s | ' $names)"
  if [ "$n" != "1" ]; then
    CARD_COUNT="$n"
    say "Hinweis: die Karten haben verschiedene Compute Capability -- ein Split braucht gleiche Karten."
    say "         (Ausnahme: eine Karte mit ECC verliert 1 GiB, das ist kein Architurkonflikt.)"
    return
  fi
  local cc; cc="$(printf '%s' "$caps" | tr -d '.')"
  [ -z "$ARCH" ] && ARCH="$cc"
  [ -z "$CARDS" ] && CARDS="$n"
}
detect_cards

if [ "$MODE" != "revert" ]; then
  [ -n "$ARCH" ] || fail "Keine Architektur ermittelt: --arch NN angeben (z.B. --arch 86)."
  [ -n "$CARDS" ] || fail "Keine Kartenanzahl ermittelt: --karten \"4\" angeben."
  case "$ARCH" in [0-9][0-9]) ;; *) fail "--arch muss zweistellig sein (86, 75, 90, 120), nicht $ARCH" ;; esac
  say "Ziel:    sm_$ARCH mit Karten-Anzahlen \"$CARDS\""
fi

# ---------------- 1) pruefen ----------------
say ""
say "== 1) Passt der Patch? =="
if ! git apply --check "$PATCH" 2>/tmp/split4_check.err; then
  say "Nein. git apply sagt:"
  sed 's/^/     /' /tmp/split4_check.err
  fail "Meist ist schon ein anderer Patch angewandt (dann erst --zurueck) oder der Stand ist ein anderer. Nichts wurde geaendert."
fi
say "     konfliktfrei."
[ "$MODE" = "check" ] && { say ""; say "Nichts geaendert (nur-pruefen)."; exit 0; }

# ---------------- 2) anwenden ----------------
say ""
say "== 2) Patch anwenden =="
if [ "$MODE" = "revert" ]; then
  git apply -R "$PATCH" && say "     zurueckgenommen. Jetzt ist update.sh sicher."
  exit 0
fi
git apply "$PATCH" || fail "Anwenden fehlgeschlagen."
say "     angewandt (nicht committet). Geaenderte Dateien:"
git status --short | sed 's/^/     /'

[ "$MODE" = "apply" ] && { say ""; say "Nicht gebaut (--ohne-bau)."; exit 0; }

# ---------------- 3) bauen ----------------
say ""
say "== 3) Bauen =="
NVCC="${CUDACXX:-}"
[ -z "$NVCC" ] && NVCC="$(command -v nvcc || true)"
[ -z "$NVCC" ] && for c in /usr/local/cuda-12.8/bin/nvcc /usr/local/cuda/bin/nvcc; do [ -x "$c" ] && NVCC="$c" && break; done
[ -n "$NVCC" ] || fail "nvcc nicht gefunden (CUDA wird zum Bauen gebraucht)."
BUILD_DIR="${BUILD_DIR:-$TREE/build-split4}"
say "nvcc:    $NVCC"
say "Build:   $BUILD_DIR"
cmake -B "$BUILD_DIR" -S "$TREE" \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_CUDA_COMPILER="$NVCC" \
      -DCMAKE_CUDA_ARCHITECTURES="$ARCH" \
      -DSTRATA_ENABLE_CUDA=ON \
      -DSTRATA_BUILD_SPLIT=ON \
      -DSTRATA_SPLIT_CARDS="$CARDS" \
      -DSTRATA_BUILD_TESTS="$([ "$TESTBUILD" = 1 ] && echo ON || echo OFF)" > "$BUILD_DIR.configure.log" 2>&1 \
  || { tail -20 "$BUILD_DIR.configure.log" | sed 's/^/     /'; fail "Konfigurieren fehlgeschlagen."; }
say "     konfiguriert."

TARGETS=""
for n in $CARDS; do TARGETS="$TARGETS strata-split-$n"; done
cmake --build "$BUILD_DIR" --target $TARGETS -j"$(nproc)" > "$BUILD_DIR.build.log" 2>&1 \
  || { grep -E "error:|Error" "$BUILD_DIR.build.log" | head -20 | sed 's/^/     /'; fail "Bauen fehlgeschlagen (Log: $BUILD_DIR.build.log)."; }
say "     gebaut."

# ---------------- 4) beweisen ----------------
say ""
say "== 4) Beweis =="
for n in $CARDS; do
  B="$BUILD_DIR/src/split/strata-split-$n"
  [ -f "$B" ] || fail "Binary fehlt: $B"
  PEER="$(nm -D --undefined-only "$B" 2>/dev/null | grep -Ec "PeerAccess|peer_access" || true)"
  say "     strata-split-$n: da, $(du -h "$B" | cut -f1), Peer-Zugriffe im Binary: $PEER (erwartet 0: Host-Ring)"
done
if [ "$SELFTEST" = 1 ]; then
  cmake --build "$BUILD_DIR" --target strata-split-selftest -j"$(nproc)" >> "$BUILD_DIR.build.log" 2>&1 \
    || { grep -E "error:" "$BUILD_DIR.build.log" | head -10 | sed 's/^/     /'; fail "Selbsttest-Bau fehlgeschlagen."; }
  ST="$BUILD_DIR/src/split/strata-split-selftest"
  i=0
  while [ "$i" -lt "${GPU_COUNT:-1}" ]; do
    say "     Karte $i:"
    "$ST" "$i" 2>&1 | sed 's/^/       /' || say "       fehlgeschlagen (exit $?)"
    i=$((i + 1))
  done
fi
if [ "$TESTBUILD" = 1 ]; then
  cmake --build "$BUILD_DIR" --target split_arch_caps_test split_card_check_test split_selftest_policy_test -j"$(nproc)" >> "$BUILD_DIR.build.log" 2>&1 || true
  for t in split_arch_caps_test split_card_check_test split_selftest_policy_test; do
    [ -x "$BUILD_DIR/src/split/$t" ] && say "     $t: $("$BUILD_DIR/src/split/$t" 2>&1 | tail -1)"
  done
fi

say ""
say "Fertig. Engine wie bisher auswaehlen (split_engine-Regel, --split-engine on); Binary: $BUILD_DIR/src/split/"
say "Zuruecknehmen vor jedem update.sh:  $0 --baum $TREE --zurueck"
