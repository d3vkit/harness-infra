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
# - chromium (xtradeb PPA, a real native-arm64 .deb — ubuntu:24.04 has no usable
#   chromium otherwise): headless browser for Cuprite/Ferrum `js: true` system specs.
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential pkg-config \
      libpq-dev postgresql-client libyaml-dev zlib1g-dev libssl-dev libreadline-dev \
    && apt-get install -y --no-install-recommends software-properties-common \
    && add-apt-repository -y ppa:xtradeb/apps \
    && apt-get update \
    && apt-get install -y --no-install-recommends chromium \
    && apt-get purge -y software-properties-common \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

USER runner
