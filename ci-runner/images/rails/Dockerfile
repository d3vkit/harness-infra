# Rails stack runner — used by kyra, pamm, postcard. Adds the toolchain a Rails CI
# job needs on top of the shared base. Validated against kyra_api's pipeline
# (scan_code, test, supabase-parity, and Cuprite/Ferrum system specs).
#
#   docker build -t harness-runner:rails --build-arg BASE_IMAGE=harness-runner:base \
#     -f images/rails/Dockerfile .
ARG BASE_IMAGE=harness-runner:base
FROM ${BASE_IMAGE}

USER root
ENV DEBIAN_FRONTEND=noninteractive

# - build-essential/pkg-config + lib*-dev: compile native gems (pg, nokogiri, …) for
#   ruby/setup-ruby's bundler-cache.
# - postgresql-client: pg_isready / psql (supabase-parity waits + extension checks).
# - imagemagick: Active Storage shells out to `convert`/`magick` to render image
#   variants (e.g. profile avatar :thumb) in system specs; without it those specs 500.
# - chromium (xtradeb PPA, a real native-arm64 .deb — ubuntu:24.04 has no usable
#   chromium otherwise): headless browser for Cuprite/Ferrum `js: true` system specs.
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential pkg-config \
      libpq-dev postgresql-client libyaml-dev zlib1g-dev libssl-dev libreadline-dev \
      imagemagick \
    && apt-get install -y --no-install-recommends software-properties-common \
    && add-apt-repository -y ppa:xtradeb/apps \
    && apt-get update \
    && apt-get install -y --no-install-recommends chromium \
    && apt-get purge -y software-properties-common \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

# Bake Ruby into the toolcache so ruby/setup-ruby finds it pre-installed and skips its
# per-run download. The ruby-builder tarball nests an `arm64/` dir, so extracting into
# the version dir yields .../Ruby/<version>/arm64/ + the `<arch>.complete` marker
# setup-ruby looks for. Self-correcting: a .ruby-version that doesn't match this baked
# version just falls back to setup-ruby's normal download (kyra/pamm/postcard are 3.4.1).
ARG RUBY_VERSION=3.4.1
RUN mkdir -p "/opt/hostedtoolcache/Ruby/${RUBY_VERSION}" \
    && curl -fsSL "https://github.com/ruby/ruby-builder/releases/download/toolcache/ruby-${RUBY_VERSION}-ubuntu-24.04-arm64.tar.gz" \
       | tar -xz -C "/opt/hostedtoolcache/Ruby/${RUBY_VERSION}" \
    && touch "/opt/hostedtoolcache/Ruby/${RUBY_VERSION}/arm64.complete" \
    && chown -R runner:runner /opt/hostedtoolcache/Ruby

USER runner
