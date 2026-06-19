# agent-harness-infra

Dedicated **shared Postgres** for the agent governance harness, used by multiple
sibling apps (e.g. [`whatchapizza`](https://github.com/d3vkit/whatchapizza),
[`kyra_api`](https://github.com/d3vkit/kyra_api)). It holds the `agent_harness`
schema: rules (centrally-owned global tiers + per-app tiers), decisions, the
`work_log` (todo / done / resume), and the other harness tables.

It lives in its own repo so neither app "owns" the shared infra; each app connects
to it over the external Docker network `agent-harness-net`. This repo is also the
**canonical owner of the global rule tiers** (see below) and holds the
[new-integration runbook](docs/runbooks/new-harness-integration.md).

## Rule tiers

The `rules.app` column is a tier. Apps load a stack-aware combination at session
start: the common `global` tier, the one `global-<stack>` tier for their stack, and
their own `app=<name>` tier.

| Tier | Applies to | Source |
|---|---|---|
| `global` | every app | `rules/global-common.md` |
| `global-rails` | Rails apps (kyra, pamm, postcard) | `rules/global-rails.md` |
| `global-expo` | Expo/RN apps (cooldown) | `rules/global-expo.md` |
| `global-godot` | Godot apps (riftling, terminal-ai) | `rules/global-godot.md` |
| `<app>` | that app only | the app's own `docs/harness/<app>-rules.md` |

The shared `app='global'` invariants are owned here too (`rules/global-invariants.json`).

## Run it

```bash
# once: create the shared external network
docker network create agent-harness-net

# bring up the harness DB
docker compose up -d
```

| Context | Address |
|---|---|
| Host (bare shell) | `127.0.0.1:55432` |
| In-container (on `agent-harness-net`) | `harness-db:5432` |

The port `55432` avoids collisions with a system Postgres (5432), the WhatchaPizza
app DB (5433), and kyra's Supabase DB (54322).

## How apps use it

- Each app's `script/lib/harness_env.sh` detects context (`/.dockerenv`) and points
  `PGHOST`/`PGPORT` at the right address, and exports `HARNESS_APP` + `HARNESS_STACK`.
- Each app's devcontainer `compose.yaml` joins `agent-harness-net` so in-container
  tooling reaches `harness-db:5432`.
- Each app seeds **only its own** tier with `HARNESS_APP=<app> ruby
  script/build_harness_db.rb` (app-scoped: it deletes/reseeds only its own rows and
  aborts if `HARNESS_APP` starts with `global`).
- Readers select tiers with `app IN ('global', 'global-'||$HARNESS_STACK, $HARNESS_APP)`.

See [docs/runbooks/new-harness-integration.md](docs/runbooks/new-harness-integration.md)
to onboard a new app or register a new stack.

## Global rule tiers (centrally owned)

The global tiers are owned **here**, not by any app. `script/build_global_rules.rb` is
the **sole writer** of every `global*` rules tier (and the shared `global` invariants);
it reseeds them from `rules/global-*.md` and `rules/global-invariants.json`:

```bash
PGHOST=127.0.0.1 PGPORT=55432 PGUSER=postgres PGPASSWORD=postgres \
  ruby script/build_global_rules.rb
```

To change a universal or stack rule, edit the relevant `rules/global-*.md` and re-run
the seeder — no per-app mirroring. (This replaces the former byte-identical-across-apps
scheme guarded by `global_rules.sha256` / `check_global_rules_sync.sh`, now retired.)
App seeders must never write a `global*` tier.

## Data

The `agent_harness` schema is created/seeded by each app's `build_harness_db.rb`
(loaded from that app's `db/harness_schema.sql` on first run). This repo only
provides the database service; it does not own the schema DDL or seed data.
The named volume `harness_pg_data` persists the data across restarts.
