#!/bin/sh
# Convert regression, the guard of Classic and of the converter: the game
# converted into a new OpenGorky project (`gorky-tool convert`, which also builds it) plays
# exactly as the Classic game. Classic from the game folder, OpenGorky from the project's
# package dist/<id>.ogp:
#   - `og-roundtrip` on the project (the OG writer gives its own files back);
#   - `convert-check`: every location's objects, variables, animation data and the texts
#     the same, and no Classic path entered (`classic paths 0`);
#   - every battle level (dat/*__*) with several seeds (`gorky-tool battle --sounds`);
#   - `world` of the five districts, the playthrough's start (`play`, 60 steps) and, with
#     $FULL, the whole playthrough (scripts/fullgame.sh): names case aside (a scene is named
#     as declared, `port-thievesa`, where the Classic code wrote `port-thievesA`).
# No OpenGorky log may say `classic paths` (gorky-tool prints it when a Classic path ran).
# Prints a line per differing log and the count of identical ones; non-zero exit on any.
#
#   scripts/convert-regress.sh <game dir> [seeds…]     (default seeds 1 7 42)
# $GORKY_TOOL — another gorky-tool, $JOBS — battles run side by side (default: CPU count),
# $KEEP — a folder to keep the Classic battle logs in (`<level>.<seed>.log`; compare two
# builds with diff -r: Classic stays byte for byte), $LEVELS — only these battle levels
# (a regress subset; no world, play), $FULL — the whole playthrough too.
# The logs carry the game's 1251 texts: byte tools (a UTF-8 sed stops at them, the compare goes blind).
export LC_ALL=C
G=${1:?game dir}
shift
SEEDS=${*:-1 7 42}
cd "$(dirname "$0")/.."
# Without $GORKY_TOOL: the optimized build, made here (scripts/release.sh).
. scripts/release.sh
TOOL=$GORKY_TOOL
TMP=${TMPDIR:-/tmp}/opengorky-convert.$$
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

OG="$TMP/project"
"$TOOL" convert "$G" "$OG" >"$TMP/convert.log" 2>&1 || { tail -5 "$TMP/convert.log"; echo "FAIL convert"; exit 1; }
PKG=$(ls "$OG"/dist/*.ogp)
FAILED=0
"$TOOL" og-roundtrip "$OG" >"$TMP/roundtrip.log" 2>&1 || { echo "FAIL og-roundtrip: $(head -1 "$TMP/roundtrip.log")"; FAILED=1; }
# Its stdout: the differences and the counts (stderr: the worlds' own warnings).
OPENGORKY_GAME=$G "$TOOL" convert-check "$G" "$PKG" >"$TMP/check.log" 2>"$TMP/check.err" || FAILED=1
tail -20 "$TMP/check.log" | sed 's/^/convert-check: /'
grep -q '^classic paths 0$' "$TMP/check.log" || { echo "FAIL convert-check: Classic paths entered"; FAILED=1; }

if [ -n "$LEVELS" ]; then
  for level in $LEVELS; do for seed in $SEEDS; do echo "$level $seed"; done; done
else
  for dir in "$G"/dat/*__*; do for seed in $SEEDS; do echo "$(basename "$dir") $seed"; done; done
fi >"$TMP/battles"
export TOOL G PKG TMP
# NUL-separated: level names have quotes (03__museum_medusa'sdeath).
tr ' \n' '\0\0' <"$TMP/battles" | xargs -0 -n 2 -P "${JOBS:-$(getconf _NPROCESSORS_ONLN)}" sh -c '
  "$TOOL" battle "$G" "$0" 60 "$1" --sounds >"$TMP/$0.$1.classic" 2>&1
  OPENGORKY_GAME=$G "$TOOL" battle "$PKG" "$0" 60 "$1" --sounds >"$TMP/$0.$1.og" 2>&1'
N=0
SAME=0
while read -r level seed; do
  N=$((N + 1))
  [ -n "$KEEP" ] && mkdir -p "$KEEP" && cp "$TMP/$level.$seed.classic" "$KEEP/$level.$seed.log"
  if [ -s "$TMP/$level.$seed.classic" ] && cmp -s "$TMP/$level.$seed.classic" "$TMP/$level.$seed.og"; then
    SAME=$((SAME + 1))
  else
    echo "DIFF battle $level seed $seed: $(diff "$TMP/$level.$seed.classic" "$TMP/$level.$seed.og" | sed -n 2p)"
  fi
done <"$TMP/battles"

# same NAME — the Classic and OpenGorky logs of a run (the game's path apart; with $2,
# names case aside).
RUNS=0
same() {
  RUNS=$((RUNS + 1))
  [ -s "$TMP/classic.log" ] && [ -s "$TMP/og.log" ] || { echo "FAIL $1: no log"; FAILED=1; return; }
  grep -q '^classic paths ' "$TMP/og.log" && { echo "FAIL $1: $(grep '^classic paths ' "$TMP/og.log")"; FAILED=1; }
  sed "s|$G|GAME|g" "$TMP/classic.log" >"$TMP/c2.log"
  sed -e "s|$PKG|GAME|g" -e "s|$G|GAME|g" "$TMP/og.log" >"$TMP/o2.log"
  if [ -n "$2" ]; then
    tr '[:upper:]' '[:lower:]' <"$TMP/c2.log" >"$TMP/c3.log" && mv "$TMP/c3.log" "$TMP/c2.log"
    tr '[:upper:]' '[:lower:]' <"$TMP/o2.log" >"$TMP/o3.log" && mv "$TMP/o3.log" "$TMP/o2.log"
  fi
  cmp -s "$TMP/c2.log" "$TMP/o2.log" && return
  echo "DIFF $1"
  diff "$TMP/c2.log" "$TMP/o2.log" | head -10 | sed 's/^/     | /'
  FAILED=1
}
if [ -z "$LEVELS" ]; then
  for level in 01_port 02_serwers 03_museum 04_city 05_laboratory; do
    "$TOOL" world "$G" "$level" 600 >"$TMP/classic.log" 2>&1
    OPENGORKY_GAME=$G "$TOOL" world "$PKG" "$level" 600 >"$TMP/og.log" 2>&1
    same "world $level"
  done
  # The start of the full playthrough (scripts/fullgame.sh): scenes, items, the first battles.
  STEPS=$(sed -n '/play \$G 01_port/,$p' scripts/fullgame.sh | tr -d '\\\n' | sed 's/.*play \$G 01_port//' | tr -s ' ' '\n' | head -60 | tr '\n' ' ')
  # shellcheck disable=SC2086
  "$TOOL" play "$G" 01_port $STEPS >"$TMP/classic.log" 2>&1
  # shellcheck disable=SC2086
  OPENGORKY_GAME=$G "$TOOL" play "$PKG" 01_port $STEPS >"$TMP/og.log" 2>&1
  same "play 01_port (60 steps)" nocase
  if [ -n "$FULL" ]; then
    GORKY_TOOL=$(cd "$(dirname "$TOOL")" && pwd)/$(basename "$TOOL")
    GORKY_TOOL=$GORKY_TOOL sh scripts/fullgame.sh "$G" >"$TMP/classic.log" 2>&1
    OPENGORKY_GAME=$G GORKY_TOOL=$GORKY_TOOL sh scripts/fullgame.sh "$PKG" >"$TMP/og.log" 2>&1
    same "fullgame" nocase
  fi
fi
for f in "$TMP"/*.og; do
  grep -q '^classic paths ' "$f" && { echo "FAIL $(basename "$f"): $(grep '^classic paths ' "$f")"; FAILED=1; }
done
if [ $SAME = $N ] && [ $FAILED = 0 ]; then echo "OK   convert: $N battle logs and $RUNS runs identical (classic vs converted), classic paths 0"; exit 0; fi
echo "FAIL convert: $SAME of $N battle logs identical"
exit 1
