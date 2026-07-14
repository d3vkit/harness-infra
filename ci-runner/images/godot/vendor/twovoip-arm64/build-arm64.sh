#!/usr/bin/env bash
# Build the native linux.arm64 twovoip libraries for a given tag (default v4.2) and drop the two
# .so files next to this script. Runs the compile inside a linux/arm64 container — native (no qemu)
# on an arm64 host, which is the only supported build host (see README.md, VEN-1300).
#
#   ./build-arm64.sh [TAG]      # e.g. ./build-arm64.sh v4.2
#
# twovoip links libopus + libRnNoise (the opus + noise-suppression-for-voice submodules), which are
# built via cmake/ninja FIRST — `scons build_opus` then `scons build_rnnoise` — before the extension
# links against them (this is upstream's documented build order; skipping it fails with -lopus /
# -lRnNoise "cannot find"). Linux needs no `scons apply_patches` (that patch fixes a Windows-only
# rnnoise link error; the godot-cpp patches are build-speed opts).
#
# Requires: Docker with a linux/arm64 daemon (Apple Silicon / arm64 Linux). Emitted files:
#   libtwovoip.linux.template_debug.arm64.so
#   libtwovoip.linux.template_release.arm64.so
set -euo pipefail
TAG="${1:-v4.2}"
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "Building twovoip ${TAG} linux.arm64 → ${HERE}"
docker run --rm --platform linux/arm64 -e TAG="$TAG" -v "$HERE":/out ubuntu:24.04 bash -euxo pipefail -c '
  export DEBIAN_FRONTEND=noninteractive
  [ "$(dpkg --print-architecture)" = "arm64" ] || { echo "FATAL: not an arm64 container/host"; exit 1; }
  apt-get update -qq
  apt-get install -y --no-install-recommends \
    git python3 scons build-essential pkg-config ca-certificates cmake ninja-build >/dev/null
  # Harden git against the HTTP/2 CANCEL flake on constrained networks (VEN-1293 family).
  git config --global http.version HTTP/1.1
  git config --global http.postBuffer 524288000
  git config --global advice.detachedHead false
  cd /tmp
  rm -rf src
  git clone --branch "$TAG" --depth 1 https://github.com/goatchurchprime/two-voip-godot-4.git src
  cd src
  n=0; until git submodule update --init --recursive --depth 1; do n=$((n+1)); [ "$n" -ge 5 ] && exit 1; echo "submodule retry $n"; sleep 4; done
  # opus + rnnoise (cmake) MUST precede the extension link.
  scons platform=linux arch=arm64 target=template_debug build_opus
  scons platform=linux arch=arm64 target=template_debug build_rnnoise
  scons platform=linux arch=arm64 target=template_debug   -j"$(nproc)"
  scons platform=linux arch=arm64 target=template_release -j"$(nproc)"
  cp -v addons/twovoip/libs/libtwovoip.linux.template_debug.arm64.so   /out/
  cp -v addons/twovoip/libs/libtwovoip.linux.template_release.arm64.so /out/
'
echo "Done. Built libraries:"
ls -la "$HERE"/*.so
file "$HERE"/*.so 2>/dev/null || true
