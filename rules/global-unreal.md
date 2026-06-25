# Global rules — Unreal stack (`global-unreal`)

Canonical source for the `app='global-unreal'` tier. These universal rules apply to every
**Unreal Engine 5 (C++)** participant (currently pirates-life) and are loaded in addition
to the common `global` tier when `HARNESS_STACK=unreal`. Seeded only by
`harness-infra/script/build_global_rules.rb`.

This is a starter set of genuinely cross-UE5 truths — grow it by consensus between the
Unreal apps. Project-specific gotchas belong in each app's `docs/harness/<app>-rules.md`.

## Engine

- Target Unreal Engine 5.x at the project's pinned engine version. Never assume UE4 APIs or deprecated classes; verify against the installed engine version.
- Networked gameplay must be server-authoritative. Replicate through the Gameplay Framework (GameMode/GameState on the server, PlayerState, replicated Pawns/Actors), mark state with `UPROPERTY(Replicated/ReplicatedUsing)` + `GetLifetimeReplicatedProps`, and never trust client-set values for gameplay-critical state.
- Prefer C++ for systems and keep Blueprints thin (content, tuning, visual wiring). AI assistants can author C++ as text but cannot author Blueprint node graphs.

## Toolchain

- Build via UnrealBuildTool (`Build.sh` on macOS) or the IDE. Never hand-edit or commit generated `Binaries/`, `Intermediate/`, `Saved/`, or `DerivedDataCache/` — they are disposable and gitignored.
- After changing reflected C++ headers (`UCLASS`/`USTRUCT`/`UPROPERTY`/`UFUNCTION`), do a full rebuild and editor restart rather than relying on Live Coding — Live Coding cannot safely hot-patch reflected type or layout changes.
- Store binary assets (`.uasset`/`.umap`/textures/audio/models) in Git LFS, never as plain git blobs.

## Architecture

- Keep gameplay logic in C++ modules; expose tunables via `UPROPERTY(EditAnywhere)`, DataAssets, and DataTables so content can be adjusted in-editor or from Blueprints without recompiling.

## Testing

- Always verify multiplayer features in-editor with Net Mode = Play As Listen Server and 2+ players, and test under simulated latency (`Net PktLag`). Single-player PIE hides replication bugs.
