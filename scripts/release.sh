# Sourced by the check scripts from the repository root: without $GORKY_TOOL, builds the
# optimized binaries (`zig build -Drelease -p zig-out/release`; a debug build plays the
# same, ~10× slower) and sets $GORKY_TOOL to its gorky-tool; exported for the scripts run
# from there. Zig's global cache stays the account's even when the run sets HOME (checks
# do): another HOME is another cache, and every build would start over (2–10 min).
if [ -z "$GORKY_TOOL" ]; then
  [ -n "$ZIG_GLOBAL_CACHE_DIR$XDG_CACHE_HOME" ] || ZIG_GLOBAL_CACHE_DIR=$(eval echo ~"$(id -un)")/.cache/zig
  # CHECK_SAFE=1 (the full check before a merge): viewer and editor ReleaseSafe, so an
  # overflow or a bad index panics instead of wrapping quietly as in ReleaseFast.
  ZIG_GLOBAL_CACHE_DIR=$ZIG_GLOBAL_CACHE_DIR zig build -Drelease ${CHECK_SAFE:+-Dviewer-optimize=ReleaseSafe} -p zig-out/release || exit 1
  GORKY_TOOL=./zig-out/release/bin/gorky-tool
fi
export GORKY_TOOL
