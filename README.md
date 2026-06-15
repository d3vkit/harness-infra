# agent-harness-infra

Dedicated **shared Postgres** for the agent governance harness, used by multiple
sibling apps (e.g. [`whatchapizza`](https://github.com/d3vkit/whatchapizza),
[`kyra_api`](https://github.com/d3vkit/kyra_api)). It holds the `agent_harness`
schema: rules (with a `global` tier + per-app tiers), decisions, the `work_log`
(todo / done / resume), and the other harness tables.

It lives in its own repo so neither app "owns" the shared infra; each app connects
to it over the external Docker network `agent-harness-net`.

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
  `PGHOST`/`PGPORT` at the right address.
- Each app's devcontainer `compose.yaml` joins `agent-harness-net` so in-container
  tooling reaches `harness-db:5432`.
- Each app seeds its own tier with `HARNESS_APP=<app> ruby script/build_harness_db.rb`
  (app-scoped: it only deletes/reseeds its own rows; the `global` tier is shared).

## Global rule-tier sync

`global_rules.sha256` is the **canonical hash** of the shared Universal Rules (the
`app='global'` harness tier). Each app's `bin/ci` runs `script/check_global_rules_sync.sh`,
which hashes its own `.github/copilot-instructions.md` (minus the per-repo marker line)
and fails if it doesn't match this value. To change universal rules: edit them
identically in **every** app repo, bump this hash in the same change, and rebuild each
app's harness. Any app left unmirrored fails CI (its rules ≠ this canonical hash).

## Data

The `agent_harness` schema is created/seeded by each app's `build_harness_db.rb`
(loaded from that app's `db/harness_schema.sql` on first run). This repo only
provides the database service; it does not own the schema DDL or seed data.
The named volume `harness_pg_data` persists the data across restarts.
