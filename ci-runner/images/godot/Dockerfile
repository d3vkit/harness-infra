# Godot stack runner — used by ephemeral (Godot 4.6). riftling / terminal-ai are still stubs.
#
#   docker build -t harness-runner:godot --build-arg BASE_IMAGE=harness-runner:base \
#     -f images/godot/Dockerfile .
ARG BASE_IMAGE=harness-runner:base
FROM ${BASE_IMAGE}

USER root
ENV DEBIAN_FRONTEND=noninteractive

# libfontconfig1 (VEN-1299): without it `godot --version` warns `libfontconfig.so.1: cannot open shared
# object file` (exit 0, so the old build-time smoke test still passed but proved only arch/version, not a
# full engine init). The current suite is pure-logic + extension smoke tests that don't render text, but
# baking it makes the smoke test real and unblocks any future font/text-rendering test.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl unzip libfontconfig1 \
    && rm -rf /var/lib/apt/lists/*

# Bake the Godot toolchain + the vendored GDExtensions INTO the image (VEN-1293) so CI jobs never
# download them from GitHub releases over the constrained dind->VM network at runtime — that path
# stalls/drops (`curl: (18) Transferred a partial file`) and reddened ephemeral's CI. Built ONCE here
# (arch-native, at the host Docker daemon where the network is unconstrained and the layer is cached),
# so every ephemeral runner starts with the toolchain already present. ephemeral's ci.yml then consumes
# /usr/local/bin/godot (its cache-check skips the download) and copies /opt/godot-vendor/{webrtc,twovoip}
# into the workspace instead of fetching them.
#
# Versions MUST track ephemeral: ci.yml GODOT_VERSION + justfile webrtc_version / twovoip_version. Bump
# here in LOCKSTEP and rebuild + redeploy this image. Fallback behaviour is now version-aware for BOTH
# artifacts (VEN-1299):
#   - Godot: ci.yml's cache-check greps `godot --version`, so a mismatch falls back to a hardened runtime
#     download (correct, just re-exposes the flake).
#   - webrtc / twovoip: we stamp /opt/godot-vendor/{webrtc,twovoip}.version below, and ci.yml's Fetch
#     steps compare that stamp to the justfile's pinned version. A bump that isn't mirrored here (stale or
#     absent stamp) now makes CI fall back to `just fetch-*` for the pinned version with a warning, instead
#     of silently testing the STALE baked copy. Still rebuild this image on a bump — the stamp only turns a
#     silent-stale-pass into a loud runtime-download (re-exposing the VEN-1293 flake), it is not a substitute.
# ephemeral is the only ACTIVE godot app (riftling / terminal-ai are stubs).
ARG GODOT_VERSION=4.6-stable
ARG WEBRTC_VERSION=1.1.0-stable
ARG TWOVOIP_VERSION=v4.2
# `just` (VEN-1299): baked so ephemeral's CI job is fully download-free — it otherwise pulls just from
# GitHub releases at runtime (extractions/setup-just) over the same constrained dind network the toolchain
# bake avoids. Pinned + arch-native (static musl build). Bump like the others and rebuild.
ARG JUST_VERSION=1.56.0

# twovoip arm64 lib (VEN-1300): the pinned twovoip v4.2 release ships NO linux.arm64 library — its
# .gdextension declares only linux.x86_64 (+ android + macos). This runner is arm64, so the baked
# upstream copy has no loadable Linux lib, the Opus classes (AudioEffectOpusChunked /
# AudioStreamOpusChunked) never register, and ~20 Opus/voice tests PEND (green, not real coverage).
# Fix: vendor a natively-built linux.arm64 v4.2 lib (built from the v4.2 source tag — upstream already
# ships android.arm64 from the same tree, so ARM is proven) and, on arm64 builds, overlay it onto the
# baked twovoip + patch the .gdextension so headless Godot loads it and the tests run for REAL. The
# COPY is unconditional (harmless on x86_64, where the RUN's arch guard skips the overlay).
COPY images/godot/vendor/twovoip-arm64/ /tmp/twovoip-arm64/

# Hardened fetch (VEN-1293): --retry-all-errors retries the partial-file transfer drop (curl exit 18)
# that plain --retry misses; `-C -` resumes across retries so progress accumulates; NO --speed-time (it
# aborts a large asset's slow tail that curl would finish — twovoip is ~120 MB). ubuntu:24.04 ships
# curl 8.x (>= 7.71, required by --retry-all-errors). dl() rm's the target first so `-C -` starts clean.
RUN set -eux; \
    dl() { rm -f "$2"; curl -fsSL --retry 8 --retry-all-errors --retry-delay 5 --connect-timeout 30 -C - "$1" -o "$2"; }; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      arm64) GARCH=linux.arm64; JARCH=aarch64-unknown-linux-musl ;; \
      amd64) GARCH=linux.x86_64; JARCH=x86_64-unknown-linux-musl ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    # --- Godot headless editor binary -> /usr/local/bin/godot ---
    dl "https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}/Godot_v${GODOT_VERSION}_${GARCH}.zip" /tmp/godot.zip; \
    unzip -tq /tmp/godot.zip >/dev/null; \
    unzip -q -o /tmp/godot.zip -d /tmp/godot; \
    install -m 0755 "/tmp/godot/Godot_v${GODOT_VERSION}_${GARCH}" /usr/local/bin/godot; \
    # --- just -> /usr/local/bin/just (prebuilt static musl tarball; binary sits at the archive root) ---
    dl "https://github.com/casey/just/releases/download/${JUST_VERSION}/just-${JUST_VERSION}-${JARCH}.tar.gz" /tmp/just.tar.gz; \
    mkdir -p /tmp/just; tar -xzf /tmp/just.tar.gz -C /tmp/just just; \
    install -m 0755 /tmp/just/just /usr/local/bin/just; \
    # --- webrtc-native GDExtension -> /opt/godot-vendor/webrtc (mirrors `just fetch-webrtc`) ---
    mkdir -p /opt/godot-vendor; \
    dl "https://github.com/godotengine/webrtc-native/releases/download/${WEBRTC_VERSION}/godot-extension-webrtc.zip" /tmp/webrtc.zip; \
    unzip -tq /tmp/webrtc.zip >/dev/null; \
    unzip -q -o /tmp/webrtc.zip -d /opt/godot-vendor; \
    # --- twovoip Opus GDExtension -> /opt/godot-vendor/twovoip (mirrors `just fetch-twovoip`) ---
    dl "https://github.com/goatchurchprime/two-voip-godot-4/releases/download/${TWOVOIP_VERSION}/TwoVoIP${TWOVOIP_VERSION}.zip" /tmp/twovoip.zip; \
    unzip -tq /tmp/twovoip.zip >/dev/null; \
    unzip -q -o /tmp/twovoip.zip "project/addons/twovoip/*" -d /tmp/twovoip-fetch; \
    mv /tmp/twovoip-fetch/project/addons/twovoip /opt/godot-vendor/twovoip; \
    # --- twovoip arm64 overlay (VEN-1300): on arm64, drop in the natively-built linux.arm64 lib and
    #     append the matching .gdextension [libraries] entries so headless Godot registers the Opus
    #     classes and the ~20 Opus/voice tests run for real. No-op on x86_64 (upstream ships x86_64). ---
    if [ "$GARCH" = "linux.arm64" ]; then \
      cp /tmp/twovoip-arm64/libtwovoip.linux.template_debug.arm64.so   /opt/godot-vendor/twovoip/libs/; \
      cp /tmp/twovoip-arm64/libtwovoip.linux.template_release.arm64.so /opt/godot-vendor/twovoip/libs/; \
      # The libs statically link twovoip/godot-cpp (MIT) + opus/rnnoise (BSD-3), whose notices must
      # travel with any binary redistribution — ship them beside the libs, as webrtc-native does.
      cp /tmp/twovoip-arm64/NOTICE /opt/godot-vendor/twovoip/NOTICE.arm64-libs; \
      printf '\nlinux.arm64 = "libs/libtwovoip.linux.template_debug.arm64.so"\nlinux.template_release.arm64 = "libs/libtwovoip.linux.template_release.arm64.so"\n' \
        >> /opt/godot-vendor/twovoip/twovoip.gdextension; \
    fi; \
    # --- Version stamps (VEN-1299): ci.yml compares these to the justfile's pinned versions and falls
    #     back to `just fetch-*` when they don't match, instead of silently testing a stale baked copy. ---
    printf '%s\n' "${WEBRTC_VERSION}" > /opt/godot-vendor/webrtc.version; \
    printf '%s\n' "${TWOVOIP_VERSION}" > /opt/godot-vendor/twovoip.version; \
    chmod -R a+rX /opt/godot-vendor; \
    rm -rf /tmp/godot.zip /tmp/godot /tmp/webrtc.zip /tmp/twovoip.zip /tmp/twovoip-fetch /tmp/twovoip-arm64 /tmp/just.tar.gz /tmp/just; \
    # Build-time smoke test: the baked toolchain loads headless. With libfontconfig1 present, `godot
    # --version` no longer warns about the missing .so, so this is a real (not shallow) engine-init check.
    godot --version; \
    just --version

USER runner
