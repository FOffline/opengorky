#!/bin/sh
# Own SDL3 build for distribution: a shared library with only video, audio and events —
# no camera, joysticks, touchpads, sensors, GPU API or tests. File and folder dialogs stay:
# the launcher and the editor pick folders with them (macOS NSOpenPanel; Linux the
# desktop portal over D-Bus or zenity).
# macOS: universal (arm64 + x86_64), Cocoa/Metal and CoreAudio; CMake, if missing, is
# downloaded into a cache (zig-out/sdl3/cmake); the system is untouched.
# Linux (scripts/dist-linux.sh, scripts/linux/dist.Dockerfile with the headers): X11,
# Wayland, ALSA, PulseAudio and PipeWire, all dlopened at run time (SDL_DEPS_SHARED), so
# the library itself needs only libc and libm.
#
#   scripts/build-sdl3.sh [dir]   — default zig-out/sdl3
# Result: <dir>/prefix/{include,lib}; game build: zig build -Dsdl-prefix=<dir>/prefix
set -e
VER=${SDL3_VERSION:-$(pkg-config --modversion sdl3 2>/dev/null || echo 3.4.14)}
CMAKE_VER=${CMAKE_VERSION:-3.31.6}
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT=${1:-$ROOT/zig-out/sdl3}
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

CMAKE=$(command -v cmake || true)
if [ -z "$CMAKE" ] && [ "$(uname)" = Darwin ]; then
  CM="$OUT/cmake"
  if [ ! -x "$CM/CMake.app/Contents/bin/cmake" ]; then
    mkdir -p "$CM"
    curl -sSLf --retry 5 --retry-all-errors "https://github.com/Kitware/CMake/releases/download/v$CMAKE_VER/cmake-$CMAKE_VER-macos-universal.tar.gz" |
      tar -xz -C "$CM" --strip-components=1
  fi
  CMAKE="$CM/CMake.app/Contents/bin/cmake"
fi

TAR="$OUT/SDL3-$VER.tar.gz"
[ -f "$TAR" ] || curl -sSLf --retry 5 --retry-all-errors -o "$TAR" "https://github.com/libsdl-org/SDL/releases/download/release-$VER/SDL3-$VER.tar.gz"
rm -rf "$OUT/src" "$OUT/build" "$OUT/prefix"
mkdir -p "$OUT/src"
tar -xzf "$TAR" -C "$OUT/src" --strip-components=1

if [ "$(uname)" = Darwin ]; then
  set -- -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 -DSDL_OPENGLES=OFF
else
  # OpenGL ES stays: Wayland needs SDL's EGL. No KMS/DRM console, sndio, JACK or IBus.
  set -- -DSDL_DEPS_SHARED=ON -DSDL_KMSDRM=OFF -DSDL_SNDIO=OFF -DSDL_JACK=OFF -DSDL_IBUS=OFF
fi
"$CMAKE" -S "$OUT/src" -B "$OUT/build" -G "Unix Makefiles" \
  -DCMAKE_BUILD_TYPE=MinSizeRel \
  -DCMAKE_INSTALL_PREFIX="$OUT/prefix" -DCMAKE_INSTALL_LIBDIR=lib "$@" \
  -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TEST_LIBRARY=OFF -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF \
  -DSDL_CAMERA=OFF -DSDL_JOYSTICK=OFF -DSDL_HAPTIC=OFF -DSDL_HIDAPI=OFF -DSDL_SENSOR=OFF \
  -DSDL_POWER=OFF -DSDL_TRAY=OFF -DSDL_GPU=OFF -DSDL_VULKAN=OFF >/dev/null
"$CMAKE" --build "$OUT/build" -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)" >/dev/null
"$CMAKE" --install "$OUT/build" >/dev/null
if [ "$(uname)" = Darwin ]; then
  lipo -info "$OUT/prefix/lib/libSDL3.0.dylib"
  du -sh "$OUT/prefix/lib/libSDL3.0.dylib"
else
  du -shL "$OUT/prefix/lib/libSDL3.so.0"
fi
