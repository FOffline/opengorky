#!/bin/sh
# Classic saves stay byte-identical: fixed scripted edits on a copy of a Classic game,
# saved, then the sha256 of every file under dat/ and of adjust.kdt (sorted), levels
# copied whole on another copy, and the shot hash of a few Info links followed. Compare the output before and after a change.
#
#   scripts/editor-golden.sh <game dir> [editor binary]
G=${1:?game dir}
# Default: the editor of the optimized build, made here (scripts/release.sh): a debug
# editor saves the same but its model previews differ in the last bits.
ED=${2:-$(cd "$(dirname "$0")/.." && . scripts/release.sh >&2 && cd "$(dirname "$GORKY_TOOL")" && echo "$PWD/opengorky-editor")} || exit 1
TMP=$(mktemp -d "${TMPDIR:-/tmp}/editor-golden.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home"
export HOME="$TMP/home" OPENGORKY_MUTE=1
cp -cR "$G" "$TMP/g" 2>/dev/null || cp -R "$G" "$TMP/g"
"$ED" "$TMP/g" --level 01__port_park \
  --set 01pr_garcia1 hp 77 --class-set 01pr_garcia2 hp 66 --move 01pr_hornet03 6 5 \
  --turn 01pr_hornet04 1.5 --remove 01pr_wcrate2 --dup 01pr_box1 --add hornet \
  --entry garcia hp 55 --entry bandage price 12 --sound garcia atakgun +gun1 --copy garcia \
  --text strings 1 Golden --dlg 01__port_park.dlg 0 text:Golden --adjust gravity 2 \
  --replace common/lang.dat:01__port_barge.dlg a b \
  --open locations 01_port --remove decha --turn bt 1.0 --save 2>&1 | sed 's/^/save: /'
(cd "$TMP/g" && find dat adjust.kdt -type f -exec shasum -a 256 {} + | LC_ALL=C sort -k2)
# levels copied whole (the tree's Duplicate, `--level-copy`): their archives, the
# battle's dialogue and voices, the location's variables under the copy's name; nothing
# else of the game changed; the copies open, and play as the originals do.
cp -cR "$G" "$TMP/c" 2>/dev/null || cp -R "$G" "$TMP/c"
"$ED" "$TMP/c" --level-copy 01__port_park 01__port_park_c --level-copy 01_port_chief 01_port_chief_c --save 2>&1 | sed 's/^/copy: /'
(cd "$TMP/c" && find dat/01__port_park_c dat/01_port_chief_c dat/common/LANG.DAT dat/common/OTHER.DAT dat/common/VOICE.DAT -type f -exec shasum -a 256 {} + | LC_ALL=C sort -k2)
echo "copy: game files changed besides: $( (cd "$TMP/c" && find dat adjust.kdt -type f ! -path 'dat/*_c/*' ! -path dat/common/LANG.DAT ! -path dat/common/OTHER.DAT ! -path dat/common/VOICE.DAT) | while read -r f; do cmp -s "$TMP/c/$f" "$G/$f" || echo "$f"; done | tr '\n' ' ')"
"$ED" "$TMP/c" --open battles 01__port_park_c 2>&1 | grep '^01__port_park_c: ' | sed 's/^/copy: /'
T="$(dirname "$ED")/gorky-tool"
"$T" battle "$TMP/c" 01__port_park 30 1 2>&1 | tail -n +2 >"$TMP/b1"
"$T" battle "$TMP/c" 01__port_park_c 30 1 2>&1 | tail -n +2 >"$TMP/b2"
cmp -s "$TMP/b1" "$TMP/b2" && echo "copy: battle as the original's ($(grep -c '^turn ' "$TMP/b2") strikes)" || echo "copy: battle differs"
"$T" play "$TMP/c" 01_port_chief_c wait:50 2>&1 | grep 'tick 50' | sed 's/^ */copy: /'
# Info rows followed (Info of an object page): where each one leads, as shown.
for o in "enemies garcia 0" "enemies garcia 1" "items bandage 0" "items bandage 1" "heroes sullivan 1" \
  "scenes museum-medusa_crazy 0" "sounds atak 0" "locations 01_port 0" "battles 01__port_park 0" "enemies hornet 2"; do
  set -- $o
  "$ED" "$TMP/g" --open "$1" "$2" --info "$3" --shot "$TMP/i.png" >/dev/null 2>&1
  echo "info $o: $(shasum -a 256 "$TMP/i.png" 2>/dev/null | cut -c1-16)"
  rm -f "$TMP/i.png"
done
