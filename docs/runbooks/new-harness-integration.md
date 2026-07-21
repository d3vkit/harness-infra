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
= ceo-sim, emerald, ephemeral, riftling, terminal-ai, vampire · **unreal** = pirates-life.

## Onboarding a new app — file checklist

Copy these from the reference implementation for your stack — **postcard** for Rails,
**project-emerald** (`~/development/games/project-emerald`) for Godot, **cooldown** for
Expo. Replace `<app>` and `<stack>` throughout.

Those three implement the contract below exactly. **Do not copy kyra_api or pamm to
onboard** — both predate this contract: neither has a `docs/harness/<app>-rules.md`, and
their seeders scrape a bespoke doc tree (`.github/copilot-instructions.md` plus
`docs/roles/*.md`) instead of parsing the rules doc, so a copied seeder points at files a
new app does not have. kyra_api remains the reference for the *optional* agent apparatus
layered on top of the harness — role docs, `script/bootstrap-agent.sh`, a PreToolUse
sentinel gate — none of which is required to participate. The files below are the whole
contract.

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
   export HARNESS_STACK="${HARNESS_STACK:-<stack>}"   # rails | expo | godot | unreal
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
   - **Hooked** (emerald/riftling/terminal-ai for Godot, kyra/pamm for Rails): a
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

   **Ordering.** Two schemes are sanctioned, and both carry the tier terms first:

   ```sql
   -- tier-ordered (session reminders): global, then stack, then app
   ORDER BY (app = 'global') DESC, (app LIKE 'global-%') DESC, id ASC;

   -- severity-ordered (bootstrap): tiers first, then critical before standard
   ORDER BY (app = 'global') DESC, (app LIKE 'global-%') DESC,
            CASE severity WHEN 'critical' THEN 0 WHEN 'standard' THEN 1 ELSE 2 END,
            id ASC;
   ```

   Never sort on `severity` directly. Severity values are `advisory`, `critical`,
   `standard`, so a plain text sort puts `critical` in the *middle* either way —
   `severity DESC` yields standard → critical → advisory. Use the `CASE` above.

   Dropping `(app LIKE 'global-%')` is not merely cosmetic: without it rows fall
   through to `id ASC`, and because the central seeder DELETEs and re-INSERTs the
   `global*` tiers on every run, the order agents see can flip from one reseed to
   the next.

6. **`script/session_context.sh`** (optional) — read/write the `work_log` table
   (`read` / `set-resume` / `add-todo` / `done` / `log`), scoped `WHERE app=$HARNESS_APP`.

7. **Contract checks** — the read path fails silently when it is wrong: a predicate
   missing a tier still returns a valid, non-empty result set, so nothing looks
   broken while a whole tier of rules never reaches an agent (VEN-1392). Two checks
   in `harness-infra/script/` guard it, and neither is forked per app:

   - **`check_harness_contract.sh [repo]`** — static, no database, milliseconds.
     Asserts `harness_env.sh` exports both discriminators and that every query
     against `agent_harness.rules` includes a `global-` tier. Wire it into the
     participant's own CI as a single step; it is the only part of this contract
     that is enforceable there.
   - **`verify_harness_readers.sh`** — functional, against the live DB. Walks every
     participant on disk, sources each app's own env, and asserts all three tiers
     come back. Host-side only: it needs sibling checkouts, which CI does not have.
     Run it after any harness change.

Then seed and verify (below). For a devcontainer, also join `agent-harness-net` in the
devcontainer compose so in-container tooling reaches `harness-db:5432` — this network join is
what makes the next point true. Any app that ships a `.devcontainer/` inherits the `global`-tier
rule that agents run the app's toolchain **inside** the running devcontainer (not on the host;
the host-side git worktree/push/PR flow stays on the host). The rule is keyed on the directory's
presence, so a new devcontainer app is covered automatically with no per-app rule to add.

## Registering a new stack

If the app's framework isn't `rails`/`expo`/`godot`/`unreal`:

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
