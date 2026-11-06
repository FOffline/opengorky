# Linux packages (scripts/dist-linux.sh): Debian 12 bookworm, so the binaries need only
# its glibc 2.36 (Ubuntu 24.04 has 2.39). SDL3 is built here (scripts/build-sdl3.sh):
# the -dev packages below are only headers — SDL3 dlopens X11, Wayland, libdecor, ALSA,
# PulseAudio, PipeWire, D-Bus and udev at run time, so none is a package dependency.
FROM debian:bookworm-slim
ARG ZIG=0.17.0
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl xz-utils pkg-config make gcc g++ libc6-dev nasm cmake \
      libx11-dev libxext-dev libxrandr-dev libxcursor-dev libxi-dev libxfixes-dev libxss-dev \
      libxtst-dev libxkbcommon-dev libwayland-dev libdecor-0-dev libasound2-dev libpulse-dev \
      libpipewire-0.3-dev libdbus-1-dev libudev-dev && \
    rm -rf /var/lib/apt/lists/*
RUN arch=$(uname -m) && \
    curl -sSLf --retry 5 --retry-all-errors https://ziglang.org/download/${ZIG}/zig-${arch}-linux-${ZIG}.tar.xz | tar -xJ -C /opt && \
    ln -s /opt/zig-${arch}-linux-${ZIG}/zig /usr/local/bin/zig
WORKDIR /src
