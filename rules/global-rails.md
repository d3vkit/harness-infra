# Global rules — Rails stack (`global-rails`)

Canonical source for the `app='global-rails'` tier. These universal rules apply to every
**Ruby on Rails** participant (currently kyra, pamm, postcard) and are loaded in addition to
the common `global` tier when `HARNESS_STACK=rails`. Seeded only by
`harness-infra/script/build_global_rules.rb`.

## Toolchain

- All tests must pass before finishing work: run `COVERAGE=1 bundle exec rspec` (and any relevant linting) before handoff or commit.
- For this Rails repo, never use generic test-runner helpers such as `runTests` or `runTest`. Use targeted `bundle exec rspec <specific_file>` directly in the devcontainer terminal instead so verification is authoritative and output stays small.
- Keep MCP server definitions canonical and synchronized. Source of truth: `docs/mcp/servers.yml`. Regenerate derived files with `ruby script/sync_mcp_configs.rb`. Do not hand-edit generated `mcp-servers` blocks in `.github/agents/playwright-test-*.agent.md` or `.mcp.json`.

## Architecture

- Every `rescue` must call `ErrorReporter.report(exception)` OR log explicitly — never swallow silently. Sentry: StandardError subclasses, provider/webhook/job failures, data corruption. Log only: validation, auth, concurrency retries, expected record-not-found. Never: `rescue => e; nil` or `rescue => e; return false`. Full examples: `docs/roles/IMPLEMENTER.md`.
- Never execute raw SQL directly. Prefer ActiveRecord query APIs first. If inadequate, prefer Arel over raw SQL strings.
- Always use `policy_scope` for all scoped record lookups in controllers. Never inline AR scoping to restrict record visibility.

## Testing

- Test sync must use Capybara/RSpec primitives only — no `sleep`, no custom polling loops (`Timeout.timeout + loop`), no `wait:` tuning in `spec/**`. Use `have_css`, `have_text`, `have_current_path`, and shared semantic helpers that delegate to those primitives.
- System specs exercise browser interactions only — `visit`, `click_button`, `fill_in`, `have_text`. Never use `page.driver.post/delete` or RSpec `post`/`delete` helpers in system specs. API contracts (including Stimulus AJAX) belong in request specs (`type: :request`). See `docs/roles/TESTER.md`.

## Workflow

- Keep docs updated when behavior changes. Update `API_CONTRACTS.md` for any change to API request/response/error behavior. Update `PRODUCTION_RUNBOOK.md` for any new or changed runtime env var. Include where operators retrieve the value. Update `README.md` for current-state behavior changes. Update `AGENTS.md` for agent workflow/guardrail changes. Update `STYLEGUIDE.md` for code-style or UI-style convention changes. Update `ROADMAP.md` for future-facing planning changes. Update `CODEBASE.md` for changes to the data model, domain vocabulary, critical workflows, or non-obvious constraints.
- When moving a Linear ticket between states, leave a comment about work completed or questions remaining. Applies to all state transitions (Backlog → In Progress → In Review → Done, and reverse). Keeps the board self-documenting so anyone can understand what happened at each stage.
- After each wave, present high-risk items one-by-one for explicit approval before moving to Done. For each ticket in Review that is not `ai-review`, present: title, 1-2 sentence summary, key risk. Approved → move to Done with comment. Denied → move back to In Progress with reason. Present one ticket at a time; wait for user response before the next.
- Follow the ticket lifecycle in `docs/runbooks/agent-workflow.md`. States: orch researches → dispatches imp (In Progress) → imp moves to In Review → rev passes (merge + Done) or returns to orch (In Progress). Never skip states; comment at every transition. For tickets with multi-approach tradeoffs: add `needs-planning`, move to Backlog, and wait for user approval before dispatch. After all subtasks' worktrees merge to branch: `COVERAGE=1 bundle exec rspec`; failures → log to ticket + return to In Progress.
