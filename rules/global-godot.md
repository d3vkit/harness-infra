# Global rules — Godot stack (`global-godot`)

Canonical source for the `app='global-godot'` tier. These universal rules apply to every
**Godot (GDScript)** participant (currently ceo-sim, emerald, ephemeral, riftling,
terminal-ai, and vampire) and are loaded in
addition to the common `global` tier when `HARNESS_STACK=godot`. Seeded only by
`harness-infra/script/build_global_rules.rb`.

This is a starter set of genuinely cross-Godot truths — grow it by consensus between the
Godot apps. Project-specific gotchas belong in each app's `docs/harness/<app>-rules.md`.

## Engine

- Target Godot 4.x (GDScript) with the project's pinned engine version. Do not assume Godot 3.x APIs.
- Always reimport the project (`Godot --headless --path . --import`) after adding or renaming a script that declares a `class_name`, before running the game or headless tests. The global class cache only refreshes on a project scan; otherwise you hit `Identifier "X" not declared`.

## Architecture

- Keep pure game logic separate from presentation and the Node tree so it stays deterministic and unit-testable headless. Logic should take its inputs (including time and RNG) as parameters rather than reaching for autoloads, `Time`, or a global RNG.

## Testing

- Always run the project's logic/unit tests headless (no editor or GUI window) so verification is authoritative and CI-able.
