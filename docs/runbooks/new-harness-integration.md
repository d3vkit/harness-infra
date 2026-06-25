# Runbook: integrating a new app (or stack) with the harness

How to connect a project to the shared agent-governance Postgres (`agent_harness` on
`127.0.0.1:55432`), and how to register a new technology stack. Read
[../../README.md](../../README.md) first for the high-level model.

## The tier model

Rules live in one table, `agent_harness.rules`, tiered by the `app` column. Every app
reads three tiers, layered:

| Tier | Who reads it | Who writes it |
|------|--------------|---------------|
| `global` | **every** app (stack-neutral rules) | harness-infra (`script/build_global_rules.rb`) |
| `global-<stack>` | apps of that stack (`rails` / `expo` / `godot`) | harness-infra (same seeder) |
| `<app>` | that app only | the app's own `script/build_harness_db.rb` |

**The golden rule:** an app seeder writes **only** its own `app=<name>` rows. It must
never insert, delete, or rewrite any `global*` tier — those are owned centrally in
`harness-infra/rules/` and seeded only by `harness-infra/script/build_global_rules.rb`.
An app seeder must `abort` if `HARNESS_APP` starts with `global`.

Current participants: **rails** = kyra, pamm, postcard · **expo** = cooldown · **godot**
= riftling, terminal-ai · **unreal** = pirates-life.

## Onboarding a new app — file checklist

Copy these from the closest same-stack participant (e.g. riftling for a Godot app,
cooldown for Expo, kyra_api for Rails). Replace `<app>` and `<stack>` throughout.

1. **`.mcp.json`** — read access via the harness MCP server. Identical across apps except
   nothing app-specific; gives the agent on-demand `query_database`:
   ```json
   {
     "mcpServers": {
       "harness": {
         "command": "/Users/<you>/.local/bin/pgedge-postgres-mcp",
         "args": [],
         "env": { "PGHOST": "127.0.0.1", "PGPORT": "55432", "PGDATABASE": "postgres",
                  "PGUSER": "postgres", "PGPASSWORD": "postgres" }
       }
     }
   }
   ```
   Note: `.mcp.json` loads only on a **fresh** Claude Code session — restart to pick it up.

2. **`script/lib/harness_env.sh`** — connection env. Detects host vs devcontainer via
   `/.dockerenv` (host → `127.0.0.1:55432`, devcontainer on `agent-harness-net` →
   `harness-db:5432`), and exports the discriminators:
   ```bash
   export HARNESS_APP="${HARNESS_APP:-<app>}"
   export HARNESS_STACK="${HARNESS_STACK:-<stack>}"   # rails | expo | godot
   ```

3. **`script/build_harness_db.rb`** — the app-scoped seeder. It parses
   `docs/harness/<app>-rules.md`, and:
   - `abort` if `HARNESS_APP` starts with `global`;
   - `DELETE FROM agent_harness.rules WHERE app = $1` (only its own tier) then re-INSERT;
   - never references any `global*` tier.
   Run it with `source script/lib/harness_env.sh && ruby script/build_harness_db.rb`.

4. **`docs/harness/<app>-rules.md`** — the app's own rules. `## Heading` = category
   (toolchain/workflow/architecture/testing/data/engine/ui), each bullet is one rule,
   severity is inferred from wording (never/must/always/do-not → `critical`).

5. **Reader (optional but recommended)** — a SessionStart hook that surfaces critical
   rules + work-log context at session start. Either:
   - **MCP-only** (cooldown's minimum): no hook; the agent queries on demand via the MCP.
   - **Hooked** (riftling/terminal-ai for Godot, kyra/pamm for Rails): a
     `.claude/settings.json` SessionStart hook running `.claude/hooks/session-reminder.sh`.
   The reader's tier selection MUST be the uniform stack-aware predicate:
   ```sql
   SELECT rule_text FROM agent_harness.rules
   WHERE app IN ('global', 'global-${HARNESS_STACK}', '${HARNESS_APP}')
     AND role = 'universal' AND severity = 'critical'
   ORDER BY (app = 'global') DESC, (app LIKE 'global-%') DESC, id ASC;
   ```
   Use the `${HARNESS_STACK:-<stack>}` / `${HARNESS_APP:-<app>}` fallback form so it is
   safe under `set -u` even if `harness_env.sh` is not sourced.

6. **`script/session_context.sh`** (optional) — read/write the `work_log` table
   (`read` / `set-resume` / `add-todo` / `done` / `log`), scoped `WHERE app=$HARNESS_APP`.

Then seed and verify (below). For a devcontainer, also join `agent-harness-net` in the
devcontainer compose so in-container tooling reaches `harness-db:5432`.

## Registering a new stack

If the app's framework isn't `rails`/`expo`/`godot`:

1. Add `harness-infra/rules/global-<stack>.md` (start minimal — a few genuinely
   cross-app rules for that stack).
2. Add the tier to `TIERS` in `harness-infra/script/build_global_rules.rb` and run it.
3. Set `HARNESS_STACK=<stack>` in the app's `harness_env.sh`. The uniform reader predicate
   needs no per-stack edits — it derives the tier name from `HARNESS_STACK`.

## Changing global / stack rules

Edit the relevant `harness-infra/rules/global-*.md` and re-run
`ruby harness-infra/script/build_global_rules.rb`. No per-app mirroring, no hashes — one
source of truth. (The old byte-identical `copilot-instructions.md` mirroring +
`global_rules.sha256` / `check_global_rules_sync.sh` scheme is retired.)

## Verification

```bash
# 1. Tiers exist and are populated:
psql ... -c "SELECT app, count(*) FROM agent_harness.rules WHERE app LIKE 'global%' GROUP BY app;"

# 2. The app loads the right combination (and nothing from other stacks):
source script/lib/harness_env.sh
psql ... -c "SELECT app, count(*) FROM agent_harness.rules
             WHERE app IN ('global','global-${HARNESS_STACK}','${HARNESS_APP}')
               AND role='universal' AND severity='critical' GROUP BY app;"

# 3. The app seeder is app-scoped (aborts on a global tier):
HARNESS_APP=global-foo ruby script/build_harness_db.rb   # must abort

# 4. Only the central seeder writes global*:
grep -rn "app = 'global'" script/   # should find nothing in an app repo
```
