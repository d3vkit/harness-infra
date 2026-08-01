# Runbook: the CI adversarial-review merge gate

**Ticket:** VEN-1526. **Status:** shared capability; kyra_api is the first adopter.

## What this is and why it exists

Participating repos protect `main` with a ruleset that requires an
`opus-adversarial-review` commit status. Until now that status was posted by a
person (or an agent, via `script/post_review_status.sh`) after a review. That is
the one step an agent cannot do for its own PR — the auto-mode classifier blocks
an agent from signing off its own work, and rightly so: a reviewer that is the
same actor as the author is not independent. The result was a human bottleneck
that stopped a ticket from going backlog → done without a person in the loop.

This gate moves the sign-off to **a machine**. A GitHub Action runs an Opus
adversarial review against the PR diff and posts the required status from that
verdict. Independence becomes structural: the thing that posts the status is CI
running a fixed, harness-owned engine — not the actor that wrote the code.

## How it works

```
PR opened/updated
  └─ caller workflow (in the app repo, on: pull_request_target)
       └─ reusable workflow  d3vkit/harness-infra/.github/workflows/adversarial-review.yml
            └─ ci-review/run_review.rb   (ubuntu-latest, Ruby stdlib)
                 1. resolve PR head SHA          (GET /pulls/{n})
                 2. skip if already decided      (GET /commits/{head}/statuses)
                 3. fetch the diff AS DATA        (GET /pulls/{n}, Accept: .diff)
                 4. one structured Opus review    (POST /v1/messages)
                 5. POST opus-adversarial-review  to the HEAD SHA
```

### Two backends, one engine (`REVIEW_BACKEND`)

The engine has two interchangeable review backends; everything else (diff
fetch, verdict → status mapping, fail-closed, head-SHA targeting) is shared:

- **`api`** (default) — calls the Anthropic Messages API with an
  `ANTHROPIC_API_KEY`. This is the CI/server path the reusable workflow uses.
- **`claude-cli`** — shells out to a local `claude -p` (Claude Code headless),
  which authenticates through the operator's **Claude subscription** — no API
  key, no per-token cost. This is the **on-demand local path** for teams on a
  subscription, run via `script/review-pr`. It posts the identical required
  status to the head SHA, so it participates in the branch-protection gate
  exactly like the API path — the ruleset does not care what produced the
  status.

**Local, on-demand usage** (subscription, no API key):

```bash
# from inside the app repo
harness-infra/script/review-pr <pr-number>
# or explicitly
harness-infra/script/review-pr d3vkit/kyra_api <pr-number>
```

It needs `gh` (authenticated), `claude` (logged in), and `ruby` — all local. It
reviews the diff with `claude -p` and posts `opus-adversarial-review` to the PR
head. Because it is on-demand, the gate is armed by default (no status = merge
blocked) and you unblock a ready PR by running the one command. Trade-offs vs.
the CI path: it only runs while your machine is up and Claude Code is logged in,
counts against your plan's usage limits, and an expired login **fails closed**
(posts `failure`/nothing — never a false approve). A subscription cannot be used
from CI (hosted or self-hosted) — local is the only place it works.

Load-bearing properties (each is asserted by `ci-review/test/run_review_test.rb`,
for **both** backends where applicable):

- **Fail closed.** `success` is posted only on a 2xx API call that parses to an
  `APPROVE` verdict. Every other outcome — API error, refusal, truncation,
  unparseable output, oversized/empty diff, `REQUEST_CHANGES` — posts `failure`
  or nothing. The ruleset requires the status *present and success*, so an
  absent status blocks a merge too.
- **Posts to the head SHA, not the merge ref.** On `pull_request_target`,
  `github.sha` is the throwaway `refs/pull/N/merge` commit; required checks are
  evaluated on the PR head. The engine resolves and targets `head.sha` (the same
  commit `post_review_status.sh` targets via `headRefOid`).
- **Idempotent.** An LLM verdict is nondeterministic and combined statuses are
  last-write-wins per (context, SHA), so the engine skips entirely if the
  context already has a status on the head SHA. A new push (new head) gets a
  fresh review. (Opus 5 rejects `temperature`, so determinism can't be pinned
  that way — skip-if-decided is the whole idempotency guarantee.)
- **Runs on `ubuntu-latest`, not the self-hosted runner.** The self-hosted CI VM
  is root-by-design with an unauthenticated privileged dind; a co-tenant job
  could read another pair's container env, so an `ANTHROPIC_API_KEY` must never
  live there. The review needs no Rails toolchain — `ubuntu-latest` ships Ruby +
  curl, and the engine is pure stdlib.

## Security posture — read before adopting

- **`pull_request_target`, not `pull_request`, is mandatory for the caller.**
  Under `pull_request` the workflow definition is taken from the PR head, so a
  rogue PR could add a job that self-posts `opus-adversarial-review=success`.
  `pull_request_target` runs the base-branch definition, so the review job and
  its caller are not PR-controlled.
- **No head code is executed.** The engine reads the diff through the GitHub
  `.diff` media type; the PR is never checked out. Combined with
  `pull_request_target` running with secrets, this is the classic pwn-request
  shape — which is why the workflow **never** checks out or runs head code and
  the key is passed explicitly, never via `secrets: inherit`.
- **Prompt injection via the diff.** The PR author controls the diff, which is
  exactly what the model reviews — a classic injection surface. The diff is
  inert (it is passed as data on stdin / in the prompt body and never executed),
  and `prompt.md` explicitly instructs the model to treat the entire diff as
  untrusted data, never as instructions, and to rest its verdict solely on the
  code's security and correctness — a diff that tries to steer the verdict is a
  red flag, never a reason to approve. This mitigates but does not mathematically
  eliminate model susceptibility; it is the same class of residual as any
  LLM-in-the-loop review, and the fail-closed design bounds the blast radius (a
  compromised verdict still cannot bypass `test`/`system-test`, and a human can
  always veto via the break-glass path).
- **Honest residual: status forgery is not closed by this design.** GitHub
  commit statuses have no per-context authorization — *any* token with
  `statuses: write` can POST `opus-adversarial-review=success` on any SHA. In
  these repos agents already hold repo-write PATs and can post statuses today,
  so this is a **pre-existing property this design neither introduces nor
  worsens** — it removes the routine agent from the path but does not make the
  status cryptographically unforgeable by a determined same-repo PR. Two
  postures:
  - **Pragmatic (current).** Accept the residual. The single-owner private-repo
    boundary plus the auto-mode classifier (which blocks ad-hoc agent status
    posts) are the controls. Adequate while there are no external forks.
  - **Full rigor (follow-up).** Post the verdict as a dedicated **GitHub App**
    check-run and pin the ruleset to that App's `integration_id`, so only the
    base-defined job (holding the App key) can satisfy the gate. This reuses the
    same engine and prompt; only the auth/posting mechanism and the ruleset pin
    change. File as a follow-up if/when the trust boundary widens.

## Provisioning a repo (one-time)

1. **Add the API key as a repo Actions secret.** In the app repo:
   Settings → Secrets and variables → Actions → New repository secret,
   name `ANTHROPIC_API_KEY`. It is passed explicitly to the reusable workflow;
   it is never stored on the self-hosted runner.
2. **Allow this repo to call harness-infra's reusable workflow.** In
   `d3vkit/harness-infra`: Settings → Actions → General → *Access* → allow
   access from repositories in the `d3vkit` organization (or list the adopting
   repo). Without this the `uses:` reference is rejected.
3. **Add the caller workflow** (below) to the app repo.
4. The app's Main ruleset already requires `opus-adversarial-review` — no
   ruleset change is needed for the pragmatic posture.

### Caller workflow (drop into the app repo)

`.github/workflows/adversarial-review.yml`:

```yaml
name: Adversarial Review

# MUST be pull_request_target: it runs THIS (base-branch) definition with
# secrets, so a PR cannot rewrite the gate to self-approve. The called workflow
# reviews the diff as data and never checks out PR code.
on:
  pull_request_target:
    types: [opened, synchronize, reopened]

concurrency:
  group: adversarial-review-${{ github.event.pull_request.number }}
  cancel-in-progress: true

permissions: {}

jobs:
  review:
    uses: d3vkit/harness-infra/.github/workflows/adversarial-review.yml@main
    permissions:
      statuses: write
      pull-requests: read
      contents: read
    with:
      repository: ${{ github.repository }}
      pr_number: ${{ github.event.pull_request.number }}
    secrets:
      ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
```

Because `pull_request_target` runs the **base** version of this file, the gate
only takes effect once this workflow is on the default branch — the PR that adds
it is not gated by it; the next PR is.

## Break-glass

`script/post_review_status.sh <PR> success|failure <desc>` in the app repo still
works and is the documented override for an engine or API outage, or a human
veto. Caveat: it writes the **same** `opus-adversarial-review` context, which is
last-write-wins — CI's next review on a new push overwrites a manual status. A
durable human *block* needs a separate channel (a draft PR, or a distinct
`human-hold` required status), not this shared context.

## harness-infra gating its own PRs

If harness-infra adds its own Main ruleset requiring `opus-adversarial-review`,
its caller must reference the engine at the **base** ref (the reusable workflow's
`harness_ref` defaults to `main`, so a PR editing `ci-review/**` is reviewed by
the base engine, not its own modified copy) and it needs its own
`ANTHROPIC_API_KEY` secret. Consider also requiring a human sign-off specifically
for diffs touching `ci-review/**` and this workflow.
