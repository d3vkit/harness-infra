# Global rules — common (all apps)

Canonical source for the shared `app='global'` tier of the harness `rules` table. These
rules are **stack-neutral** and apply to every participating app regardless of framework.
Seeded only by `harness-infra/script/build_global_rules.rb`. Each `## Heading` is a
category; each bullet is one rule; severity is inferred from the wording
(never/must/always/do-not/non-negotiable → critical).

Stack-specific universal rules live in the sibling files `global-rails.md`,
`global-expo.md`, and `global-godot.md`, each seeded into its own `global-<stack>` tier.

## Workflow

- Prefer removing obsolete paths outright over keeping deprecated compatibility layers. If code, docs, scripts, or workflows are no longer the intended path, delete or rewrite them directly unless there is a strong, explicit reason to preserve compatibility.
- Prefer what the framework or engine already provides over bypassing it. If a bypass is necessary, document the reason in code comments.
- Provide a direct status update in chat when implementation is complete or attention is required. Include completion/blocked state and the exact next action needed from the user when applicable.
- No repository-managed cross-repo handoff docs. Summarize cross-repo work directly in the task/PR/thread context.
- Use the Explore subagent to offload research tasks — it runs separately and returns only a summary, not raw file contents.
- Use `| tail -N` or `| grep` when running commands that produce verbose output.
- Never checkout, change, or merge into the `main` branch. All work happens on feature branches. Agent worktree branches merge into the feature branch, never into `main`. `main` is the production branch — only the user or CI merges into it.
- Our focus is on writing high quality code the first time no matter how long that takes. We don't need to move fast.
- Keep docs updated when behavior changes. Update the project's documentation — README plus any architecture, design, runbook, API, or roadmap docs — whenever behavior, interfaces, runtime env vars, the data model, or critical workflows change. (Stack-specific apps may pin exact filenames in their stack or app tier.)
- New agent rules and guardrails must be saved to the harness, never to ad-hoc or file-based memory. Add app-specific rules to your app's `docs/harness/<app>-rules.md` (or role docs) and rebuild your app tier; propose universal or stack rules by editing the canonical files in `harness-infra/rules/`. The harness is the canonical rule store.
- Always read and update the harness work log. Read current context at the start of any work — latest resume note, open TODOs, recent done in `agent_harness.work_log` (via the SessionStart hook, `script/session_context.sh read`, or an MCP query). Before finishing or handing off, write back: `log`/`done` completed items, `add-todo` new work, `set-resume` a fresh handoff note. The harness work log — not chat scrollback or ad-hoc docs — is the canonical home for work-to-do / done / resume.
- Global rule tiers are centrally owned in `harness-infra/rules/` and seeded only by `harness-infra/script/build_global_rules.rb`. The `global` tier applies to every app; the `global-rails`, `global-expo`, and `global-godot` tiers apply to apps of that stack (selected at read time via `HARNESS_STACK`). Never seed or rewrite any `global*` tier from an app seeder — app seeders write only their own `app=<name>` rows and must abort if `HARNESS_APP` starts with `global`. To change a universal or stack rule, edit the canonical file in `harness-infra/rules/` and re-run the central seeder.

## Architecture

- Apply SOLID and clean-design principles — single responsibility, clear boundaries, dependency inversion. Prefer small, well-named units over large multi-purpose ones.
- Never swallow errors silently. Every caught exception must be reported or logged explicitly, with enough context to diagnose it — never discard an error and continue. (The specific reporting mechanism is a stack concern.)

## Testing

- All tests must pass before finishing work. Run the project's full test suite and any relevant linting before handoff or commit. Any failures — whether caused by your changes or pre-existing — must be fixed. Fix all warnings and errors in tests, build output, type checks, and runtime logs. Never silence or defer without a documented exception.
- Prefer correctness over speed. If a code change breaks existing tests, investigate why before adjusting anything. Do not weaken a test to preserve a green run.
- Never skip, hide, or remove failing tests to force a green run. A breaking test may be exposing a previously hidden bug. Fix the root cause in the code under test or the test's incorrect assumptions. Do not delete an agent-written test to make it pass — debug the failure and rewrite incorrect assertions; only remove a test if it is truly a duplicate or covers behavior that no longer exists.
