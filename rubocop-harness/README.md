# rubocop-harness

Shared RuboCop cops that enforce the **mechanically decidable** parts of the
cross-app comment policy owned in harness-infra
(`rules/global-common.md`, `## Comments`). Whether a comment is "explanatory" is
a judgement call and is deliberately **not** encoded here — these cops only catch
the shapes a machine can decide.

One gem, consumed by every harness Rails app (kyra, pamm, postcard), so the rules
have a single source of truth — the same reason the `global*` rule tiers live in
harness-infra.

## Cops

| Cop | Default | Flags |
|-----|---------|-------|
| `Harness/CommentBlockLength` | on, `Max: 4` | A run of consecutive comment lines longer than `Max`. Extended rationale belongs in a design doc with a one-line pointer. |
| `Harness/CommentedOutCode` | on | A standalone comment block that is valid Ruby with a structural node (assignment, def/class, block) or a dot-call on a solid receiver. Conservative by design (see below). |
| `Harness/AnnotationTicketRef` | on | A `TODO`/`FIXME`/`HACK`/`XXX`/`OPTIMIZE` annotation with no tracker reference (default pattern `[A-Z]{2,}-\d+`). |
| `Harness/BannerComment` | on, `MinRepeat: 4` | A decorative divider banner (`# ====`, `# ----`). |
| `Harness/NarrationComment` | **off** | A lone comment above a method that only narrates it (`# Returns the user`). High false-positive risk — enable per app after a burn-down. |

### `Harness/CommentedOutCode` is intentionally conservative

Distinguishing commented-out code from prose is heuristic. This cop errs toward
**missing** some commented code rather than flagging prose: a block is reported
only when, after stripping `#`, it is valid Ruby **and** its AST holds a
structural node or a dot-call on a concrete receiver (a constant, ivar, or
`self`). Prose that happens to parse — `e.g. the user`, `per-subscription`, a
`docs/design/foo.md` path, a `delete it if stale` modifier — is left alone.
Labeled/indented usage examples (a `Usage:` or `@example` header followed by
`#   code`) are skipped via `AllowIndentedExamples`.

The false negatives are absorbed by the roll-out process: `.rubocop_todo.yml`
grandfathers the existing corpus (VEN-1542) and the hand-triage sweep (VEN-1547)
catches what the heuristic misses.

## Use in an app

Add the gem from its git source and require it in `.rubocop.yml`:

```ruby
# Gemfile
gem "rubocop-harness", git: "https://github.com/d3vkit/harness-infra.git", glob: "rubocop-harness/*.gemspec"
```

```yaml
# .rubocop.yml
require:
  - rubocop-harness
```

The cop defaults (`config/default.yml`) are injected automatically; override any
of them per app under the matching `Harness/*` key. Wiring into kyra with a
grandfathering `.rubocop_todo.yml` is VEN-1542; the pamm/postcard roll-out is
VEN-1544.

## Development

```bash
cd rubocop-harness
bundle install
bundle exec rspec
```
