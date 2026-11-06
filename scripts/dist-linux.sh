#!/bin/sh
# Linux packages: zig-out/dist/opengorky-linux-<arch>.tar.xz and, separately, the level
# editor opengorky-editor-linux-<arch>.tar.xz (the editor and SDL3), built in the
# scripts/linux/dist.Dockerfile container (Debian 12 bookworm: glibc 2.36+; Zig 0.17).
# Contains: the viewer (ReleaseFast, no debug info, rpath $ORIGIN/lib) with FFmpeg and LAME
# linked statically (scripts/build-ffmpeg.sh, gcc in the container; LGPL), lib/ with our
# SDL3 (scripts/build-sdl3.sh: X11, Wayland and the sound servers dlopened, so a desktop
# system needs no extra packages), licenses, the launcher opengorky [game dir], icon
# opengorky.png and opengorky.desktop.
#
#   scripts/dist-linux.sh [game dir]   — OPT=ReleaseFast to optimize for speed
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OPT=${OPT:-ReleaseFast}
GAME=${1:-}
mkdir -p "$ROOT/zig-out/dist"
VER=$(git -C "$ROOT" describe --always --dirty 2>/dev/null || echo dev)
SRCURL=$(git -C "$ROOT" remote get-url origin 2>/dev/null | sed 's/\.git$//' || true)
# Optional game dir argument: check that a video decodes.
set --
[ -n "$GAME" ] && set -- -v "$GAME":/game:ro
docker build -q -t opengorky-linux-dist -f "$ROOT/scripts/linux/dist.Dockerfile" "$ROOT/scripts/linux" >/dev/null
docker run --rm "$@" -v "$ROOT":/src:ro -v "$ROOT/zig-out/dist":/out -v opengorky-linux-dist-cache:/cache \
  -e ZIG_GLOBAL_CACHE_DIR=/cache/global -e OPT="$OPT" -e VER="$VER" -e SRCURL="$SRCURL" opengorky-linux-dist sh -c '
    set -e
    cp -r /src /work && cd /work && rm -rf zig-out .zig-cache
    sh scripts/build-ffmpeg.sh /work/zig-out/ffmpeg >/dev/null 2>&1
    sh scripts/build-sdl3.sh /work/zig-out/sdl3
    SDL=/work/zig-out/sdl3/prefix/lib/libSDL3.so.0
    zig build -Doptimize=ReleaseSafe -Dviewer-optimize="$OPT" -Dstrip=true -Dversion="$VER" -Dtool=false \
      -Dffmpeg-prefix=/work/zig-out/ffmpeg/prefix -Dsdl-prefix=/work/zig-out/sdl3/prefix -Dbundle-rpath="\$ORIGIN/lib" -p /work/zig-out/b
    ARCH=$(uname -m)
    D=/work/zig-out/opengorky
    mkdir -p $D/lib $D/licenses
    cp zig-out/b/bin/opengorky-viewer $D/
    cp -L "$SDL" $D/lib/
    strip -s $D/lib/libSDL3.so.0
    cp LICENSE $D/licenses/OpenGorky-MIT.txt
    cp third_party/clay/LICENSE.md $D/licenses/Clay-zlib.txt
    cp assets/fonts/OFL.txt $D/licenses/PTSans-OFL.txt
    cp assets/fonts/OFL-Oswald.txt $D/licenses/Oswald-OFL.txt
    cp zig-out/sdl3/src/LICENSE.txt $D/licenses/SDL3-zlib.txt
    cp zig-out/ffmpeg/src/COPYING.LGPLv2.1 $D/licenses/FFmpeg-LGPL-2.1.txt
    cp zig-out/ffmpeg/lame/COPYING $D/licenses/LAME-LGPL-2.txt
    printf "%s\n" "OpenGorky — MIT. SDL3 — zlib (lib/). Clay — zlib. stb_truetype, stb_image, stb_image_write — public domain; dr_wav, dr_mp3 — public domain or MIT-0. PT Sans, Oswald fonts — SIL OFL 1.1." \
      "FFmpeg $(cat zig-out/ffmpeg/src/VERSION) — LGPL 2.1+, and LAME 3.100 — LGPL 2+: linked statically into the program." \
      "To relink it with your own (modified) FFmpeg or LAME: the complete source of the program is the" \
      "relinkable form — ${SRCURL:-the OpenGorky repository}, version $VER; build the libraries with" \
      "scripts/build-ffmpeg.sh (or your own), then zig build -Dffmpeg-prefix=<build>/prefix (README)." \
      "Library sources: https://ffmpeg.org/releases/, https://lame.sourceforge.io/." > $D/licenses/README.txt
    printf "%s\n" "#!/bin/sh" "# opengorky [Gorky 17 dir with dat/ and avi/] [flags]; no arguments: the launcher window" \
      "HERE=\$(cd \"\$(dirname \"\$0\")\" && pwd)" "[ \$# -eq 0 ] && exec \"\$HERE/opengorky-viewer\"" "G=\$1; shift" \
      "exec \"\$HERE/opengorky-viewer\" \"\$G\" --play \"\$@\"" > $D/opengorky
    chmod +x $D/opengorky
    # Icon and app-menu entry (Exec: set the package path on install).
    cp assets/icon-256.png $D/opengorky.png
    printf "%s\n" "[Desktop Entry]" "Type=Application" "Name=OpenGorky" \
      "Comment=Gorky 17 (needs the original game files)" "Exec=opengorky %f" \
      "Icon=opengorky" "Categories=Game;RolePlaying;" "Terminal=false" > $D/opengorky.desktop
    # Check: hard dependencies only SDL3 from the package and glibc (X11, Wayland, sound
    # are dlopened by SDL3), FFmpeg inside the binary, glibc 2.36 at most, a video decodes.
    for f in $D/opengorky-viewer zig-out/b/bin/opengorky-editor $D/lib/libSDL3.so.0; do
      readelf -d $f | awk "/NEEDED/{print \$5}" | tr -d "[]" | grep -vxE "libSDL3.so.0|libc.so.6|libm.so.6|libdl.so.2|libpthread.so.0|ld-linux-.*" && { echo "$f: extra hard dependency" >&2; exit 1; }
      objdump -T $f | grep -oE "GLIBC_2\.[0-9]+" | sort -uV | tail -1 | grep -qxE "GLIBC_2\.([0-9]|[12][0-9]|3[0-6])" || { echo "$f: needs glibc newer than 2.36" >&2; exit 1; }
    done
    ldd $D/opengorky-viewer | grep SDL3 | grep -q "$D/lib/" || { echo "viewer: SDL3 not from the package" >&2; exit 1; }
    if [ -d /game/dat ]; then
      SDL_VIDEODRIVER=offscreen SDL_AUDIODRIVER=dummy $D/opengorky-viewer /game 01_port/sprite.dat \
        --level --time 5000 --video incubus.avi --shot /tmp/v.png 2>&1 | grep video
    fi
    tar -C /work/zig-out -cJf /out/opengorky-linux-$ARCH.tar.xz opengorky
    du -sh $D /out/opengorky-linux-$ARCH.tar.xz
    # Level editor: the game folder is chosen in its settings (or given as the argument).
    E=/work/zig-out/opengorky-editor
    mkdir -p $E/lib $E/licenses
    cp zig-out/b/bin/opengorky-editor $E/
    cp $D/lib/* $E/lib/
    cp $D/licenses/OpenGorky-MIT.txt $E/licenses/
    cp $D/licenses/SDL3-zlib.txt $E/licenses/
    cp third_party/clay/LICENSE.md $E/licenses/Clay-zlib.txt
    cp assets/fonts/OFL.txt $E/licenses/PTSans-OFL.txt
    cp assets/icons/LICENSE-lucide.txt $E/licenses/Lucide-ISC.txt
    cp $D/licenses/FFmpeg-LGPL-2.1.txt $D/licenses/LAME-LGPL-2.txt $E/licenses/
    { echo "Clay — zlib. stb_truetype, stb_image, stb_image_write — public domain; dr_wav, dr_mp3 — public domain or MIT-0. PT Sans — SIL OFL 1.1. Lucide icons — ISC."; cat $D/licenses/README.txt; } > $E/licenses/README.txt
    cp assets/icon-editor-256.png $E/opengorky-editor.png
    printf "%s\n" "[Desktop Entry]" "Type=Application" "Name=OpenGorky Editor" \
      "Comment=Gorky 17 level editor (edits a copy of the game files)" "Exec=opengorky-editor" \
      "Icon=opengorky-editor" "Categories=Development;Game;" "Terminal=false" > $E/opengorky-editor.desktop
    ldd $E/opengorky-editor | grep SDL3 | grep -q "$E/lib/" || { echo "editor: SDL3 not from the package" >&2; exit 1; }
    tar -C /work/zig-out -cJf /out/opengorky-editor-linux-$ARCH.tar.xz opengorky-editor
    du -sh $E /out/opengorky-editor-linux-$ARCH.tar.xz
  '
