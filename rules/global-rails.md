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

- When moving a Linear ticket between states, leave a comment about work completed or questions remaining. Applies to all state transitions (Backlog → In Progress → In Review → Done, and reverse). Keeps the board self-documenting so anyone can understand what happened at each stage.
- After each wave, move every ticket that passed its gate to Done automatically, with a comment recording the passing gate — an Opus adversarial review signed off, no open questions or issues remain for the user, and CI is green on GitHub. Passing the gate is the authorization: do not present tickets for user approval or wait for a response before moving them. Move a ticket back to In Progress only when a specific gate condition genuinely fails, recording which one; a failed review returns to In Progress with the reason.
- Follow the ticket lifecycle in `docs/runbooks/agent-workflow.md`. States: orch researches → creates the feature branch and pushes it to the remote, then dispatches imp (In Progress) → imp commits, pushes its worktree branch, and opens its PR against the feature branch (`gh pr create --base <feature-branch>`, never against `main`) → imp moves to In Review → rev passes (merge + Done) or returns to orch (In Progress). Orch must push the feature branch to the remote before dispatching, not after subtasks merge: `gh pr create --base <feature-branch>` fails if that base does not yet exist on the remote, so an unpushed feature branch leaves every imp unable to open its PR at all. Pushing and opening the PR are part of reaching In Review, not a later favor: a ticket must never enter In Review on a branch that is still local-only, because the adversarial review and the CI signal its gate depends on both read that PR. The orchestrator owns the feature branch on the same terms — it keeps that branch pushed as subtask branches merge into it, and opens its own PR against `main`; a feature branch is never exempt merely because its commits arrived by merge rather than by orch's own hand. Never skip states; comment at every transition. Only when a ticket has genuinely unresolved multi-approach tradeoffs that require the user to choose direction, add `needs-planning`, move to Backlog, and pause for that decision before dispatch — a genuine open question is the sole reason to wait; tickets with a clear path (including ones with ordinary implementation tradeoffs) dispatch automatically without asking. After all subtasks' worktrees merge to branch: `COVERAGE=1 bundle exec rspec`; failures → log to ticket + return to In Progress.
