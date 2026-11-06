#!/bin/sh
# OpenGorky projects edited by the editor: fixed scripted
# edits (fields, an inner block's field, an attach's struct list, an inner block added, a
# field taken out, abilities rows — a battle's fighter's by its object's name; a new
# character and weapon, a fighter moved and the camera turned on the level page, a post
# chain, the test kit) on the hand-written test project and on the game converted, saved;
# then the sha256 of every file under src/ (sorted, the outputs to compare before and after
# a change), the lines the edits changed, and the checks that the edited projects still
# build (gorky-tool build) and play (a battle to its end; the test room with the kit), and
# that the saves' history is .og/history. a name typed (the block's `name`), a new
# battle object (into the battle's battle.ogs: a battle is one text), the new weapon's own ammo, the kit's enemy
# weapon, `.og/` in .gitignore. a weapon's ammo by archetype (`ammo = ~i"…"`), a
# scene off (`enabled = false`), the level page's assets (walk map, areas, battle grid) and an
# imported sound saved as the project's own (src/assets/), "+ fighter" on a free tile.
# a weapon's "Ammo" row (`thrown = true`, none), a location's `entry` point, a
# trigger area and an exit written as OG Script (logic.ogs, objects.ogs), an area renamed
# with its references, the party joining in a trigger, a scene renamed and a point of it
# put on the map, the level's picture, depth and paths as own assets. a trigger's
# variable in the level block (level.ogs); on a copy of the converted game without src/assets/
# and with a level without logic.ogs: the engine sees the first own asset saved in the same
# session (`--engine-level`), the first trigger and exit make the level's logic.ogs, a trigger
# block turned off by its level variable (no comments). Release: the installed game is
# never written (mtimes). new levels made in the project's src/ (from a level, blank, a
# whole copy; built, played, listed in the next session), a scene's lines edited in place
# (the dialog block's Line rows, the scenes' DIALOG_DISPLAY numbers). a weapon's effect
# fields (`--weapon-fx`). a silent line's own recording; a copied level's objects named
# as its own (its scenes naming them copied), its battle as the original's. Exit code:
# non-zero on FAIL.
#
#   scripts/editor-golden-og.sh <game dir> [editor binary]
G=${1:?game dir}
cd "$(dirname "$0")/.."
# Without $GORKY_TOOL: the optimized build, made here (scripts/release.sh).
. scripts/release.sh
TOOL=$GORKY_TOOL
ED=${2:-$(dirname "$TOOL")/opengorky-editor}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/editor-golden-og.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home"
export HOME="$TMP/home" OPENGORKY_MUTE=1 OPENGORKY_GAME="$G"
FAILED=0
fail() { echo "FAIL $1"; FAILED=1; }

cp -R src/tests/og/port "$TMP/tp"
"$TOOL" convert "$G" "$TMP/cv" >"$TMP/convert.log" 2>&1 || { echo "FAIL convert: $(tail -1 "$TMP/convert.log")"; exit 1; }
cp -R "$TMP/tp" "$TMP/tp0"
cp -R "$TMP/cv/src" "$TMP/cv0"
cp -R "$TMP/cv" "$TMP/cn"
cp -R "$TMP/cv" "$TMP/ga"
# Release check: no editor session on a project writes the installed game (its mtimes).
touch "$TMP/game.stamp"
B='battles/01__port_citadel/battle.ogs'
"$ED" "$TMP/tp" --og-set characters/grandma.ogs hp 250 --og-set characters/grandma.ogs resist_gas - \
  --og-set "$B#grandma_child2" hp 41 --og-set "$B#grandma_child2/gun" place backpack \
  --og-attach "$B" Reinforcements waves '[Wave(turn = 2, spawn = [Spawn(who = ~c"characters::grandma_child", tile = [5, 2])])]' \
  --og-inner characters/grandma.ogs item bandage items::bandage --ability grandma double_turn + \
  --og-inner "$B" fighter extra characters::grandma_child --og-set "$B#extra" tile '[3, 8]' \
  --og-name weapons/grandma_child.ogs 'Детская рогатка' --save 2>&1 | sed 's/^/save tp: /'
P='battles/01__port_park/battle.ogs'
"$ED" "$TMP/cv" --og-set characters/sullivan.ogs hp 150 --og-set "$P#01pr_hornet02" hp 5 \
  --og-set looks/hornet.ogs walk '[Speed(anim = "walk", speed = 3.0)]' --og-remove "$P#01pr_hornet03" \
  --ability sullivan double_turn + --ability "$P#01pr_hornet04" immobile + --save 2>&1 | sed 's/^/save cv: /'
# new archetypes, the level page's placement and camera, a post chain, the kit.
"$ED" "$TMP/cv" --char-new --weapon-new --open battles 01__port_park --move 01pr_hornet05 6 5 --move Sullivan 8 16 \
  --camera eye_x 1 --post-for 01_port --post add grade - \
  --test-kit "sullivan weapons::shotgun 1 hand" --test-kit "sullivan items::shotgun_ammo 30" \
  --weapon-fx riffle launch_from weapons::rocket_launcher --weapon-fx riffle hit_sound s_expl1 --save 2>&1 | sed 's/^/save cv2: /'
# ammo by archetype, a scene off, level assets and a sound into src/assets/, a new
# battle fighter on a free tile.
python3 -I -c 'import sys,wave; w=wave.open(sys.argv[1],"wb"); w.setnchannels(1); w.setsampwidth(2); w.setframerate(22050); w.writeframes(bytes(4410*2)); w.close()' "$TMP/beep_og.wav"
"$ED" "$TMP/cv" --og-set weapons/riffle.ogs ammo '~i"items::pistolammo"' --scene-off port-arriv_at_port \
  --sound-import "$TMP/beep_og.wav" --open locations 01_port --level-paint walk,100,100,300,300,1 --level-done \
  --area-move capt_start 20,10 --open battles 01__port_park --level-paint grid,400,300,500,400,1 --level-done \
  --og-fighter battles/01__port_park/battle.ogs characters::ovitz --save 2>&1 | sed 's/^/save cv3: /'
# ammo row, entry point, triggers and exits on OG, a scene renamed and its point,
# picture, depth and paths.
python3 -I -c 'import sys,zlib,struct
w,h=640,480
raw=b"".join(b"\x00"+bytes([int(sys.argv[2]),40,40])*w for _ in range(h))
ch=lambda t,d: struct.pack(">I",len(d))+t+d+struct.pack(">I",zlib.crc32(t+d)&0xffffffff)
open(sys.argv[1],"wb").write(b"\x89PNG\r\n\x1a\n"+ch(b"IHDR",struct.pack(">IIBBBBB",w,h,8,2,0,0,0))+ch(b"IDAT",zlib.compress(raw))+ch(b"IEND",b""))' "$TMP/pic.png" 90
cp "$TMP/pic.png" "$TMP/depth.png"
"$ED" "$TMP/cv" --og-ammo weapons/pistol.ogs thrown --og-ammo weapons/grenade.ogs none \
  --og-entry 01_port_tunnel exit2port --og-entry 01_port_chief - \
  --open locations 01_port_store --level-area '100,300;200,300;200,400;100,400' --level-done \
  --level-exit 01_port '400,300;500,300;500,400;400,400' --level-done --area-rename exit2port gate \
  --trigger-hero trigger1 Sullivan join --level-layer-in picture "$TMP/pic.png" --level-layer-in depth "$TMP/depth.png" --level-done \
  --scene-rename port-deska port-deska2 --open scenes port-arriv_at_port --open locations 01_port --scene-point 1500,300 \
  --path-new --path-node 900,900 --save 2>&1 | sed 's/^/save cv4: /'
# a level without logic.ogs (its components' attaches gone with it), no src/assets/.
C="$TMP/cn/src/locations/01_port_citadel"
rm "$C/logic.ogs" && sed -i.bak '/attach /d' "$C/objects.ogs" && rm "$C/objects.ogs.bak"
python3 -I -c 'import sys,zlib,struct
w,h=800,600
raw=b"".join(b"\x00"+bytes([90,40,40])*w for _ in range(h))
ch=lambda t,d: struct.pack(">I",len(d))+t+d+struct.pack(">I",zlib.crc32(t+d)&0xffffffff)
open(sys.argv[1],"wb").write(b"\x89PNG\r\n\x1a\n"+ch(b"IHDR",struct.pack(">IIBBBBB",w,h,8,2,0,0,0))+ch(b"IDAT",zlib.compress(raw))+ch(b"IEND",b""))' "$TMP/pic800.png"
[ ! -e "$TMP/cn/src/assets" ] || fail "assets session cn: the converted game has src/assets/"
"$ED" "$TMP/cn" --engine-level 01_port_citadel --open locations 01_port_citadel --level-layer-in picture "$TMP/pic800.png" --level-done \
  --save-now --engine-level 01_port_citadel --level-area '100,300;200,300;200,400;100,400' --level-done --trigger-off trigger1 \
  --level-exit 01_port '400,300;500,300;500,400;400,400' --level-done --save >"$TMP/cn.log" 2>&1
sed 's/^/save cn: /' "$TMP/cn.log"
[ "$(grep -c '^engine 01_port_citadel: background ' "$TMP/cn.log")" = 2 ] && grep -q '^engine 01_port_citadel: background 800×600$' "$TMP/cn.log" &&
  echo "OK   assets session cn" || fail "assets session cn: the engine does not see the new src/assets/"
grep -q '^level "01_port_citadel" {$' "$C/logic.ogs" && grep -q 'if (ready_trigger1 and hero::AnyInArea("trigger1")) {' "$C/logic.ogs" &&
  grep -q '^    component exit1_are for area {$' "$C/logic.ogs" && grep -q '^module locations::_01_port_citadel {$' "$C/logic.ogs" &&
  ! grep -q 'var bool ready_' "$C/logic.ogs" && grep -q '^    var bool ready_trigger1 = false;$' "$C/level.ogs" &&
  ! grep -rq '//#ed' "$TMP/cn/src" && echo "OK   new logic cn" || fail "new logic cn"
"$TOOL" build "$TMP/cn" >"$TMP/cn.build" 2>&1 && echo "OK   build cn" || fail "build cn: $(grep -i error "$TMP/cn.build" | head -1)"
OPENGORKY_GAME=$G "$TOOL" play "$TMP/cn/dist/gorky.ogp" 01_port_citadel wait:50 goto:exit1 wait:50 >"$TMP/cn.exit" 2>&1
grep -q 'transition 01_port_citadel -> 01_port$' "$TMP/cn.exit" && echo "OK   exit play cn" || fail "exit play cn: $(tail -1 "$TMP/cn.exit")"
for p in tp cv; do
  (cd "$TMP/$p" && find src .og/testkit.txt -type f \( -name '*.ogs' -o -name '*.txt' \) -exec shasum -a 256 {} + 2>/dev/null | LC_ALL=C sort -k2 | sed "s/^/$p /")
done
echo "changed tp:"; diff -r "$TMP/tp0/src" "$TMP/tp/src" | grep '^[<>]'
echo "changed cv:"; diff -r "$TMP/cv0" "$TMP/cv/src" | grep '^[<>]'
# the new weapon's own ammo (a copy of the rifle's) is what it uses; names on the blocks;
# the new object in the battle's battle.ogs; .og/ out of git.
# No classic_id on a new block (the OG reader numbers it by its path); its name its own field.
nm=$(sed -n 's/^ *name = "\(.*\)";$/\1/p' "$TMP/cv/src/items/new_weapon_1_ammo.ogs" 2>/dev/null | head -1)
[ -n "$nm" ] && ! grep -q 'classic_id' "$TMP/cv/src/items/new_weapon_1_ammo.ogs" "$TMP/cv/src/weapons/new_weapon_1.ogs" &&
  grep -q '^ *ammo = ~i"items::new_weapon_1_ammo";' "$TMP/cv/src/weapons/new_weapon_1.ogs" &&
  ! grep -qF "\"$nm\"" "$TMP/cv/src/texts/ui.ogs" &&
  echo "OK   ammo cv" || fail "ammo cv: new_weapon_1 does not use its own ammo"
grep -q '^ *name = "Детская рогатка";$' "$TMP/tp/src/weapons/grandma_child.ogs" && echo "OK   name tp" || fail "name tp: no name on weapons::grandma_child"
grep -q '^    fighter extra: characters::grandma_child {$' "$TMP/tp/src/battles/01__port_citadel/battle.ogs" &&
  [ ! -e "$TMP/tp/src/battles/01__port_citadel/objects.ogs" ] && echo "OK   objects tp" || fail "objects tp: extra not in battle.ogs"
grep -q '^ *ammo = ~i"items::pistolammo";$' "$TMP/cv/src/weapons/riffle.ogs" && echo "OK   ammo ref cv" || fail "ammo ref cv: riffle"
# a weapon's effects are its fields (no FxAs row in OpenGorky), a stage by reference.
grep -q '^ *launch_from = ~w"weapons::rocket_launcher";$' "$TMP/cv/src/weapons/riffle.ogs" && grep -q '^ *hit_sound = "s_expl1";$' "$TMP/cv/src/weapons/riffle.ogs" &&
  ! grep -rq 'FxAs(' "$TMP/cv/src" && echo "OK   weapon fx cv" || fail "weapon fx cv: riffle"
grep -q '^    enabled = false;$' "$TMP/cv/src/scenes/port-arriv_at_port.ogs" && echo "OK   scene off cv" || fail "scene off cv"
for f in sounds/beep_og.wav levels/01_port/walk.wm levels/01_port/areas.ar levels/01__port_park/grid.cm; do
  [ -s "$TMP/cv/src/assets/$f" ] || fail "assets cv: no src/assets/$f"
done
[ -s "$TMP/cv/src/assets/levels/01__port_park/grid.cm" ] && echo "OK   assets cv"
grep -A1 '^    fighter ovitz_1: characters::ovitz {$' "$TMP/cv/src/battles/01__port_park/battle.ogs" | grep -q '^        tile = \[' &&
  echo "OK   fighter cv" || fail "fighter cv: ovitz_1 has no tile"
# thrown, ammo none, entry, trigger and exit in OG Script, rename, scene, point, assets.
W="$TMP/cv/src/weapons"
grep -q '^ *thrown = true;$' "$W/pistol.ogs" && ! grep -q 'ammo' "$W/pistol.ogs" &&
  ! grep -q 'thrown\|ammo' "$W/grenade.ogs" && ! grep -rq 'ammoUsed' "$TMP/cv/src" && echo "OK   thrown cv" || fail "thrown cv"
Lc="$TMP/cv/src/locations"
grep -q '^    entry = "exit2port";$' "$Lc/01_port_tunnel/level.ogs" && ! grep -q 'entry' "$Lc/01_port_chief/level.ogs" &&
  [ "$(grep -c '^    entry = ' "$Lc"/*/level.ogs | grep -c ':1$')" = 8 ] && echo "OK   entry cv" || fail "entry cv"
S="$Lc/01_port_store"
grep -q 'if (ready_trigger1 and hero::AnyInArea("trigger1")) {' "$S/logic.ogs" && grep -q 'hero::SetInParty("Sullivan", 1);' "$S/logic.ogs" &&
  grep -q '^    component exit1_are for area {$' "$S/logic.ogs" && grep -q 'level::Load(~l"01_port");' "$S/logic.ogs" &&
  grep -q '^    var bool ready_trigger1 = true;$' "$S/level.ogs" && ! grep -q 'var bool ready_' "$S/logic.ogs" &&
  grep -q '^    area exit1_are {$' "$S/objects.ogs" && grep -q 'areaName = "gate";' "$S/objects.ogs" && ! grep -rq '"exit2port"' "$S" &&
  grep -q 'areaName: gate' "$TMP/cv/src/assets/levels/01_port_store/areas.ar" && echo "OK   triggers cv" || fail "triggers cv"
[ -s "$TMP/cv/src/scenes/port-deska2.ogs" ] && [ ! -e "$TMP/cv/src/scenes/port-deska.ogs" ] && grep -rq '~e"port-deska2"' "$Lc/01_port" &&
  ! grep -rq '"port-deska"' "$TMP/cv/src" && echo "OK   scene rename cv" || fail "scene rename cv"
grep -q 'Point(name = "p1", x = 1500.0, y = 300.0, angle = 0.0)' "$TMP/cv/src/scenes/port-arriv_at_port.ogs" && echo "OK   scene point cv" || fail "scene point cv"
for f in levels/01_port_store/background.jpg levels/01_port_store/background.zbf levels/01_port/paths.ap; do
  [ -s "$TMP/cv/src/assets/$f" ] || fail "level assets cv: no src/assets/$f"
done
[ -s "$TMP/cv/src/assets/levels/01_port/paths.ap" ] && echo "OK   level assets cv"
for p in tp cv; do
  grep -qx '.og/' "$TMP/$p/.gitignore" && echo "OK   gitignore $p" || fail "gitignore $p: no .og/"
done
# The saves' history: in the project's .og/history (outside src/ and the package).
for p in tp cv; do
  [ -s "$TMP/$p/.og/history/log.txt" ] && echo "OK   history $p" || fail "history $p: no .og/history/log.txt"
done
# The edited projects build and play.
for p in tp cv; do
  "$TOOL" build "$TMP/$p" >"$TMP/$p.build" 2>&1 && echo "OK   build $p" || fail "build $p: $(grep -i error "$TMP/$p.build" | head -1)"
done
# The scene turned off never starts (the converted game's first scene).
OPENGORKY_GAME=$G "$TOOL" play "$TMP/cv/dist/gorky.ogp" 01_port wait:300 scene >"$TMP/cv.play" 2>&1 &&
  ! grep -q "scene 'port-arriv_at_port'" "$TMP/cv.play" && echo "OK   scene off play cv" || fail "scene off play cv"
# The new exit leads to 01_port.
OPENGORKY_GAME=$G "$TOOL" play "$TMP/cv/dist/gorky.ogp" 01_port_store wait:50 goto:exit1 wait:50 >"$TMP/cv.exit" 2>&1
grep -q 'transition 01_port_store -> 01_port$' "$TMP/cv.exit" && echo "OK   exit play cv" || fail "exit play cv: $(tail -1 "$TMP/cv.exit")"
"$TOOL" battle "$TMP/tp" 01__port_citadel 30 1 >"$TMP/tp.battle" 2>&1 && grep -q '^grandma .* hp 250 ' "$TMP/tp.battle" &&
  grep -q '^  spawn grandma_child enemy at 5,2 on turn 2$' "$TMP/tp.battle" && grep -q '^result: ' "$TMP/tp.battle" &&
  grep -q '^extra .*tile 3,8' "$TMP/tp.battle" &&
  echo "OK   play tp" || fail "play tp: $(tail -1 "$TMP/tp.battle")"
"$TOOL" battle "$TMP/cv" 01__port_park 60 1 >"$TMP/cv.battle" 2>&1 && grep -q '^01pr_hornet02 .* hp 5 ' "$TMP/cv.battle" &&
  ! grep -q '^01pr_hornet03 ' "$TMP/cv.battle" && grep -q '^result: ' "$TMP/cv.battle" &&
  grep -q '^01pr_hornet05 enemy tile 6,5 ' "$TMP/cv.battle" && grep -q '^sullivan .* tile 8,16 ' "$TMP/cv.battle" &&
  grep -q '^ovitz_1 *enemy tile ' "$TMP/cv.battle" &&
  echo "OK   play cv" || fail "play cv: $(tail -1 "$TMP/cv.battle")"
# The test room of the new character (its own weapons), the kit's shotgun in Sullivan's
# hand (more rounds than a pistol's 12).
"$ED" "$TMP/cv" --test-room new_character_1 >"$TMP/cv.room" 2>&1 && "$TOOL" battle "$TMP/cv/dist/play.ogp" 04__city_passing 60 1 >"$TMP/cv.room" 2>&1 &&
  held=$(awk '/^sullivan +hero / { print $NF; exit }' "$TMP/cv.room") &&
  [ "$(awk -v w="$held" '$1 == w ":" && $2 == "ammo" { print $3; exit }' "$TMP/cv.room")" -gt 12 ] && grep -q '^result: ' "$TMP/cv.room" &&
  grep -qE '^puppet +enemy ' "$TMP/cv.room" &&
  echo "OK   room cv" || fail "room cv: $(tail -1 "$TMP/cv.room")"
# The installed game untouched by everything above and by more operations on a project of
# its own (a scene, a script, imports, copies, effects, new archetypes, the test room, a mod
# package, a roll-back); new levels go into the project's src/, never the game's dat/.
python3 -I -c 'import sys,zlib,struct
w,h=64,64
raw=b"".join(b"\x00"+bytes([90,40,40])*w for _ in range(h))
ch=lambda t,d: struct.pack(">I",len(d))+t+d+struct.pack(">I",zlib.crc32(t+d)&0xffffffff)
open(sys.argv[1],"wb").write(b"\x89PNG\r\n\x1a\n"+ch(b"IHDR",struct.pack(">IIBBBBB",w,h,8,2,0,0,0))+ch(b"IDAT",zlib.compress(raw))+ch(b"IEND",b""))' "$TMP/pic64.png"
for s in "--scene-new --script-new --save" "--blank-new zz_new --open locations 01_port --location-new 01_port_c2 --save" \
  "--level-copy 01_port_chief 01_port_chief_c --level-copy 01__port_park 01__port_park_c --level-copy 01_port 01_port_cc --blank-new 09__zz_b --save" \
  "--dlg port-arriving.dlg 1 text:Слышали? --dlg port-arriving.dlg 0 down --dlg port-arriving.dlg 2 add --dlg port-arriving.dlg 3 voice-file:$TMP/beep_og.wav --save" \
  "--music-import $TMP/beep_og.wav zz_music --sound-import $TMP/beep_og.wav --save" \
  "--texture-import sullivan $TMP/pic64.png --icon-import pistol $TMP/pic64.png --sprite-import icons $TMP/pic64.png --save" \
  "--copy pistol --effect-new --fx-new pistol --char-new --weapon-new --save" "--test-room sullivan" "--package $TMP/ga_pkg" "--roll-back 1 --save"; do
  # shellcheck disable=SC2086
  "$ED" "$TMP/ga" $s >>"$TMP/ga.log" 2>&1
done
# the new levels' blocks and assets in the project's src/ (none in the game's dat/).
GS="$TMP/ga/src"
grep -q '^level "zz_new" {$' "$GS/locations/zz_new/level.ogs" && grep -q '^    entry = "capt_start";$' "$GS/locations/01_port_c2/level.ogs" &&
  grep -q '^    camera = Camera(' "$GS/locations/01_port_c2/level.ogs" && grep -q '^battle "09__zz_b" {$' "$GS/battles/09__zz_b/battle.ogs" &&
  [ -s "$GS/assets/levels/zz_new/background.jpg" ] && [ -s "$GS/assets/levels/01_port_c2/walk.wm" ] && [ -s "$GS/assets/levels/09__zz_b/grid.cm" ] &&
  [ -s "$GS/locations/01_port_chief_c/level.ogs" ] && [ -s "$GS/locations/01_port_chief_c/logic.ogs" ] && [ -s "$GS/locations/01_port_chief_c/objects.ogs" ] &&
  grep -q '^level "01_port_chief_c" {$' "$GS/locations/01_port_chief_c/logic.ogs" && ! grep -rq '01_port_chief\b' "$GS/locations/01_port_chief_c" &&
  [ -s "$GS/assets/levels/01_port_chief_c/sprites/09_sejf.spr" ] && [ -s "$GS/assets/levels/01__port_park_c/grid.cm" ] &&
  grep -q '^    active_anim "01_port_chief_c_09_sejf" {$' "$GS/locations/01_port_chief_c/objects.ogs" && grep -q '^        sprite = "09_sejf";$' "$GS/locations/01_port_chief_c/objects.ogs" &&
  grep -rq 'item::NewWeapon("01_port_chief_c_01pch_shocker", "weapons::shocker");' "$GS/locations/01_port_chief_c" &&
  grep -q '^dialog "01__port_park_c" {$' "$GS/dialogs/01__port_park_c.ogs" && grep -rq 'scene::Start(~e"01_port_cc_gateopen");' "$GS/locations/01_port_cc" &&
  grep -q '^    object::Impulse(@"01_port_cc_console1", 2);$' "$GS/scenes/01_port_cc_gateopen.ogs" && grep -q '^    object::Impulse(@console1, 2);$' "$GS/scenes/gateopen.ogs" &&
  grep -rq 'actor::Place("01_port_cc_ponton", "ponton", 0);' "$GS/locations/01_port_cc" &&
  [ ! -e "$G/dat/zz_new" ] && [ ! -e "$G/dat/01_port_c2" ] && [ ! -e "$G/dat/01_port_chief_c" ] &&
  echo "OK   new levels ga" || fail "new levels ga: $(grep -i level "$TMP/ga.log" | head -1)"
# A scene's lines: the text, the move (each line keeps its voice), a new line without one, then
# given a file of its own; the scenes showing the dialog by number follow.
D="$GS/dialogs/port-arriving.ogs"
sed -n 2p "$D" | grep -q 'who = "Sullivan", text = "Слышали?", voice = ~s"voice/port_arriving_su_01.wav"' && sed -n 3p "$D" | grep -q 'who = "Ovitz".*port_arriving_ov_00.wav' &&
  sed -n 5p "$D" | grep -q '^    Line(who = "Trantigne", text = "...", voice = ~s"voice/port_arriving_tr_03.wav");$' && [ -s "$GS/assets/voice/port_arriving_tr_03.wav" ] &&
  grep -q 'dialog::Say(4);' "$GS/scenes/port-arriv_at_port.ogs" &&
  echo "OK   scene lines ga" || fail "scene lines ga: $(sed -n 2,4p "$D" | cut -c1-80 | tr '\n' ' ')"
"$TOOL" build "$TMP/ga" >"$TMP/ga.build" 2>&1 && echo "OK   build ga" || fail "build ga: $(grep -i error "$TMP/ga.build" | head -1)"
for l in zz_new 01_port_c2 01_port_chief_c 01_port_cc; do
  OPENGORKY_GAME=$G "$TOOL" play "$TMP/ga/dist/gorky.ogp" $l wait:50 >"$TMP/ga.play" 2>&1 && grep -q "($l, tick 50: " "$TMP/ga.play" || fail "play ga $l: $(tail -1 "$TMP/ga.play")"
done
for b in 01__port_park_c 09__zz_b; do
  "$TOOL" battle "$TMP/ga/dist/gorky.ogp" $b 30 1 >"$TMP/ga.battle" 2>&1 && grep -q '^result: ' "$TMP/ga.battle" || fail "play ga $b: $(tail -1 "$TMP/ga.battle")"
done
# The copy has the original's fighters (named as its own) and fights as the original does
# (its dialog, shown by the battle's name, copied too).
"$TOOL" battle "$TMP/ga/dist/gorky.ogp" 01__port_park 30 1 2>&1 | tail -n +2 | tr -s ' ' >"$TMP/ga.b0"
"$TOOL" battle "$TMP/ga/dist/gorky.ogp" 01__port_park_c 30 1 2>&1 | tail -n +2 | sed 's/01__port_park_c_//g' | tr -s ' ' >"$TMP/ga.b1"
"$TOOL" battle "$TMP/ga/dist/gorky.ogp" 01__port_park_c 30 1 2>&1 | grep -q '^01__port_park_c_01pr_hornet02 enemy tile 19,14 ' && cmp -s "$TMP/ga.b0" "$TMP/ga.b1" &&
  echo "OK   play ga" || fail "play ga: the copied battle has not its enemies or fights otherwise"
# The next session lists them (the level page opens a level the game has none of).
"$ED" "$TMP/ga" --engine-level zz_new --open locations zz_new >"$TMP/ga.open" 2>&1
"$ED" "$TMP/ga" --open battles 09__zz_b >>"$TMP/ga.open" 2>&1
grep -q '^engine zz_new: background 640×480$' "$TMP/ga.open" && grep -q '^zz_new: ' "$TMP/ga.open" && grep -q '^09__zz_b: ' "$TMP/ga.open" &&
  echo "OK   new levels listed ga" || fail "new levels listed ga: $(grep -v avi "$TMP/ga.open" | head -2 | tr '\n' ' ')"
# The code window's problems on a project's texts: OG Script parse and link errors,
# no false ones on the converted game (rows naming no entity the converter drops).
printf 'module x {\n  fn F() { var int a = ; }\n  fn G() { hero::NoSuchThing(1); }\n}\n' >"$TMP/ga/src/broken.ogs"
# a monster whose weapon needs ammo it has not (unarmed, as in the exe).
printf 'module characters {\n    fighter zz_gunner {\n        classic_id = 3001;\n        weapon gun: weapons::pistol {\n            place = hand;\n        }\n    }\n}\n' >"$TMP/ga/src/characters/zz_gunner.ogs"
# a stage field's number no block has and no built-in effect is.
printf 'module weapons {\n    weapon zz_gun {\n        classic_id = 3002;\n        hit_from = 5555;\n        flash_from = 98;\n    }\n}\n' >"$TMP/ga/src/weapons/zz_gun.ogs"
"$ED" "$TMP/ga" --code-check-all >"$TMP/ga.check" 2>&1
grep -q '^src|broken.ogs:2: expected a value$' "$TMP/ga.check" && [ "$(grep -c '^src|' "$TMP/ga.check")" = 3 ] &&
  grep -q '^src|characters/zz_gunner.ogs: line 4: zz_gunner: weapon gun needs ammo items::pistolammo' "$TMP/ga.check" &&
  grep -q '^src|weapons/zz_gun.ogs: line 4: hit_from = 5555: no block has classic_id 5555' "$TMP/ga.check" &&
  echo "OK   code check ga" || fail "code check ga: $(grep -c '^src|' "$TMP/ga.check") problems: $(grep '^src|' "$TMP/ga.check" | tr '\n' ' ')"
# The AI page's tile scoring: the profile block's own fields, no rules row (one field
# changed, the rest kept).
"$ED" "$TMP/ga" --scoring garcia weapons first --scoring garcia follow_lock false --save >"$TMP/ga.sc" 2>&1
grep -q '^        weapons = first;$' "$TMP/ga/src/ai/garcia.ogs" && grep -q '^        follow_lock = false;$' "$TMP/ga/src/ai/garcia.ogs" &&
  ! grep -q 'scoring' "$TMP/ga/src/ai/garcia.ogs" && [ ! -e "$TMP/ga/src/rules/ai.ogs" ] &&
  echo "OK   scoring ga" || fail "scoring ga: $(cat "$TMP/ga/src/ai/garcia.ogs" | tr '\n' ' ') $(ls "$TMP/ga/src/rules" | tr '\n' ' ')"
[ -z "$(find "$G" -newer "$TMP/game.stamp" | head -1)" ] && echo "OK   game untouched" || fail "game untouched: $(find "$G" -newer "$TMP/game.stamp" | head -3 | tr '\n' ' ')"
exit $FAILED
