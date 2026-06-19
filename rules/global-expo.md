# Global rules — Expo / React Native stack (`global-expo`)

Canonical source for the `app='global-expo'` tier. These universal rules apply to every
**Expo / React Native** participant (currently cooldown) and are loaded in addition to the
common `global` tier when `HARNESS_STACK=expo`. Seeded only by
`harness-infra/script/build_global_rules.rb`.

This is a starter set — grow it as cross-Expo conventions emerge. Keep app-specific rules in
each app's `docs/harness/<app>-rules.md`.

## Toolchain

- Read the exact versioned Expo docs for the SDK this app targets (e.g. `https://docs.expo.dev/versions/v<SDK>.0.0/`) before writing any Expo or React Native code. Expo changes across SDKs; do not rely on memory of older versions.

## Architecture

- Prefer Expo-provided modules and config plugins over reaching for bare-workflow native changes; if you must drop to native, document why and keep it behind a config plugin so prebuild stays reproducible.
