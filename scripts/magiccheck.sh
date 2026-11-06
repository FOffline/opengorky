#!/bin/sh
# Magic check: the engine knows no game. The original's numbers
# and names (its levels, objects, characters, sounds, music, script files, its levelMode
# and classic_id special cases) live in the Classic reader only: core/classic.zig (the hand
# rows) and the composition/parsers (compose/, formats/, script/classic/). Any such
# literal in engine code (the core, audio, the viewer) fails, unless a line of
# scripts/magiccheck.allow names the file (and the literal without spaces, or *) with the
# reason.
# Comments, doc text (\\ lines, `pub const doc = "…"`) and test blocks are not code and are
# not checked.
# Prints OK or the offending lines; non-zero exit on any. layercheck.sh runs it.
#
#   scripts/magiccheck.sh
cd "$(dirname "$0")/../src" || exit 1
ALLOW=../scripts/magiccheck.allow

ENGINE="rules.zig fields.zig game.zig popup.zig outbox.zig actor.zig battle.zig combat.zig
inventory.zig state.zig world.zig scene.zig fx.zig effects.zig builtins.zig audio.zig core.zig
core rules battle combat inventory state world scene game builtins fx effects actor audio
script viewer"

# The game's literals: a string literal containing one (case-insensitive) fails.
NAMES='"0[0-9]__?[a-z][a-z_0-9]*(\.dlg|\.mtm)?"|sullivan|ovitz|trantigne|lamar|hutchens|mac ?fadden|slavsky|medusa|"hq"|lilith|grandma|gs_fist|"timebomb|"distractor|(ft|wp|cw)_[a-z_]+\.ss?"|\.dlg"|\.mtm"|"(selecthero|invgive|itemchoose|itemput|invselect|granat|battle_noammo|upgrade_setpoints|takeitems1|safekey|invbutton(weapons|items|keys)|health2|battle_menuslide_(in|out)|transformation|pull_barell|pull_wood_box|click|keyboard|menu1|keyaccept|victory|gameover|statistics|battle[23]|_enemy|fightlook|g_fightlook|deliriuma|introkon|__)"'
# The game's special cases in code: a level's `mode` or classic_id compared with a number.
CODE='"mode"\)[^;]*(==|!=) *[1-9][0-9]*|(nameI[dD]|classicId)\([^)]*\) *(==|!=) *[1-9][0-9]*|\.id *(==|!=) *[1-9][0-9]*'
export NAMES CODE

files=$(for p in $ENGINE; do
  if [ -d "$p" ]; then find "$p" -name '*.zig'; else echo "$p"; fi
done | grep -v '^script/classic/' | grep -v '^core/classic\.zig$' | sort -u)

# file:line:text of the code lines (no comments, doc text or test blocks).
code() {
  awk '
    /^test / { t = 1 } t && /^}/ { t = 0; next } t { next }
    /^[ \t]*\/\// || /^[ \t]*\\\\/ || /^[ \t]*pub const doc = / { next }
    { s = $0; out = ""; q = 0
      for (i = 1; i <= length(s); i++) { c = substr(s, i, 1)
        if (c == "\\" && q) { out = out c substr(s, i + 1, 1); i++; continue }
        if (c == "\"") q = !q
        if (!q && c == "/" && substr(s, i + 1, 1) == "/") break
        out = out c }
      print FILENAME ":" FNR ":" out }' "$@"
}

hits=$(code $files | awk -F: '
  BEGIN { names = ENVIRON["NAMES"]; codere = ENVIRON["CODE"] }
  { line = substr($0, length($1) + length($2) + 3); low = tolower(line); hit = ""
    s = line
    while (match(s, /"[^"]*"/)) { lit = substr(s, RSTART, RLENGTH); if (tolower(lit) ~ names) { hit = lit; break } s = substr(s, RSTART + RLENGTH) }
    if (hit == "" && match(line, codere)) hit = substr(line, RSTART, RLENGTH)
    gsub(/ /, "", hit)
    if (hit != "") print $1 "\t" hit "\t" $2 ": " line }')

FAILED=0
used=""
echo "$hits" | while IFS='	' read -r f lit where; do
  [ -n "$f" ] || continue
  ok=$(awk -v f="$f" -v lit="$lit" '!/^#/ && NF >= 2 && $1 == f && ($2 == "*" || $2 == lit) { print "y"; exit }' "$ALLOW")
  [ -n "$ok" ] || echo "FAIL game literal in engine code: $f:$where"
done >"${TMPDIR:-/tmp}/magiccheck.$$"
out=$(cat "${TMPDIR:-/tmp}/magiccheck.$$")
rm -f "${TMPDIR:-/tmp}/magiccheck.$$"
[ -n "$out" ] && { echo "$out"; FAILED=1; }
# An allowlist line that matches nothing: fixed, drop it.
stale=$(awk '!/^#/ && NF >= 2 { print $1 "\t" $2 }' "$ALLOW" | while IFS='	' read -r f lit; do
  echo "$hits" | awk -F'\t' -v f="$f" -v lit="$lit" '$1 == f && (lit == "*" || $2 == lit) { found = 1 } END { exit !found }' || echo "FAIL magiccheck.allow: fixed, drop the line: $f $lit"
done)
[ -n "$stale" ] && { echo "$stale"; FAILED=1; }
[ $FAILED = 0 ] && echo "OK   magic ($(echo "$hits" | grep -c .) allowed literals in $(awk '!/^#/ && NF >= 2 { print $1 }' "$ALLOW" | sort -u | grep -c .) files, scripts/magiccheck.allow)"
exit $FAILED
