#!/usr/bin/env ruby
# frozen_string_literal: true

# Unit tests for the CI adversarial-review engine (VEN-1526).
#
# Runs with no network and no gems beyond minitest (a Ruby default gem):
#   ruby ci-review/test/run_review_test.rb
#
# The engine's HTTP is injected (NetHTTPTransport seam), so every request is
# served by a FakeTransport that records what was sent and returns canned
# responses. This lets us assert the load-bearing guarantees directly:
#   * verdict -> status-state mapping, BOTH directions (VEN-1310: a check that
#     cannot go red proves nothing — success and failure must each be reachable);
#   * fail-closed on every error path (oversized/empty diff, API non-2xx,
#     refusal, truncation, unparseable output);
#   * the status is posted to the PR HEAD sha, not a merge ref;
#   * idempotent skip when the context already has a status on the head;
#   * the 140-char status-description clamp;
#   * the request actually asks the API for a schema-constrained verdict.

require 'minitest/autorun'
require 'json'
require_relative '../run_review'

class FakeTransport
  attr_reader :requests

  def initialize(&responder)
    @responder = responder
    @requests = []
  end

  def call(method, uri, headers, body, _timeout)
    @requests << { method: method, uri: uri.to_s, headers: headers, body: body }
    @responder.call(method, uri, headers, body)
  end
end

class FakeClaude
  attr_reader :calls

  def initialize(out:, ok: true, err: '')
    @out = out
    @ok = ok
    @err = err
    @calls = []
  end

  def call(argv, stdin, _timeout)
    @calls << { argv: argv, stdin: stdin }
    [@out, @ok, @err]
  end
end

module ReviewFixtures
  HEAD_SHA = 'deadbeefcafe1234deadbeefcafe1234deadbeef'
  PR_URL   = 'https://github.com/d3vkit/kyra_api/pull/42'

  def base_env(overrides = {})
    {
      'GITHUB_REPOSITORY' => 'd3vkit/kyra_api',
      'PR_NUMBER' => '42',
      'GITHUB_TOKEN' => 'ghtoken',
      'ANTHROPIC_API_KEY' => 'sk-test',
      'PROMPT_PATH' => File.expand_path('../prompt.md', __dir__)
    }.merge(overrides)
  end

  def anthropic_ok(verdict:, summary: 'ok', findings: [])
    verdict_json = JSON.generate('verdict' => verdict, 'summary' => summary, 'findings' => findings)
    JSON.generate(
      'stop_reason' => 'end_turn',
      'content' => [
        { 'type' => 'thinking', 'thinking' => '' },
        { 'type' => 'text', 'text' => verdict_json }
      ]
    )
  end

  # A programmable responder. Pass any of the keyword overrides to steer one
  # leg of the flow; everything else uses a sane default.
  def responder(opts = {})
    existing_statuses = opts.fetch(:existing_statuses, [])
    diff = opts.fetch(:diff, "--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n")
    anthropic = opts # :anthropic_code, :anthropic_body, :verdict, :summary
    status_code = opts.fetch(:status_post_code, 201)

    lambda do |method, uri, headers, _body|
      path = uri.path
      if method == :get && path.end_with?("/statuses") # combined statuses on head
        [200, JSON.generate(existing_statuses)]
      elsif method == :get && path.include?('/pulls/') && headers['Accept'] == 'application/vnd.github.diff'
        [opts.fetch(:diff_code, 200), diff]
      elsif method == :get && path.include?('/pulls/')
        [opts.fetch(:pr_code, 200),
         JSON.generate('head' => { 'sha' => HEAD_SHA }, 'html_url' => PR_URL)]
      elsif method == :post && path.include?('/v1/messages')
        code = anthropic.fetch(:anthropic_code, 200)
        body = anthropic.fetch(:anthropic_body) do
          anthropic_ok(verdict: anthropic.fetch(:verdict, 'APPROVE'),
                       summary: anthropic.fetch(:summary, 'looks good'),
                       findings: anthropic.fetch(:findings, []))
        end
        [code, body]
      elsif method == :post && path.include?('/statuses/')
        [status_code, '{}']
      else
        raise "unexpected request: #{method} #{uri}"
      end
    end
  end

  def run_engine(env_overrides = {}, opts = {})
    transport = FakeTransport.new(&responder(opts))
    code = CIReview::Engine.new(base_env(env_overrides), transport: transport).run
    [code, transport]
  end

  # A `claude -p --output-format json` envelope.
  def claude_envelope(result, is_error: false, subtype: 'success')
    JSON.generate('type' => 'result', 'subtype' => subtype, 'is_error' => is_error, 'result' => result)
  end

  def verdict_json(verdict: 'APPROVE', summary: 'ok', findings: [])
    JSON.generate('verdict' => verdict, 'summary' => summary, 'findings' => findings)
  end

  # claude-cli backend env intentionally has NO ANTHROPIC_API_KEY — the local
  # backend authenticates through the Claude Code login, not an API key.
  def cli_env(overrides = {})
    base_env(overrides).tap { |e| e.delete('ANTHROPIC_API_KEY') }
                       .merge('REVIEW_BACKEND' => 'claude-cli')
  end

  def run_engine_cli(env_overrides, opts, claude)
    transport = FakeTransport.new(&responder(opts))
    code = CIReview::Engine.new(cli_env(env_overrides), transport: transport, claude_runner: claude).run
    [code, transport]
  end

  def status_posts(transport)
    transport.requests.select { |r| r[:method] == :post && r[:uri].include?('/statuses/') }
  end

  def model_calls(transport)
    transport.requests.select { |r| r[:method] == :post && r[:uri].include?('/v1/messages') }
  end

  def last_status(transport)
    JSON.parse(status_posts(transport).last[:body])
  end
end

class RunReviewTest < Minitest::Test
  include ReviewFixtures

  # --- verdict mapping, both directions (VEN-1310) -----------------------

  def test_approve_posts_success_to_head_sha
    code, tx = run_engine({}, verdict: 'APPROVE', summary: 'clean diff')
    assert_equal 0, code
    posts = status_posts(tx)
    assert_equal 1, posts.size
    assert_includes posts.last[:uri], "/statuses/#{ReviewFixtures::HEAD_SHA}"
    body = last_status(tx)
    assert_equal 'success', body['state']
    assert_equal 'opus-adversarial-review', body['context']
    assert_equal 'clean diff', body['description']
    assert_equal ReviewFixtures::PR_URL, body['target_url']
  end

  def test_request_changes_posts_failure
    code, tx = run_engine({}, verdict: 'REQUEST_CHANGES', summary: 'auth bypass')
    assert_equal 1, code
    assert_equal 'failure', last_status(tx)['state']
  end

  # The success and failure legs are exercised together above; this asserts the
  # mapping cannot collapse (a real gate must reach both states).
  def test_mapping_reaches_both_states
    _, approve_tx = run_engine({}, verdict: 'APPROVE')
    _, reject_tx  = run_engine({}, verdict: 'REQUEST_CHANGES')
    assert_equal 'success', last_status(approve_tx)['state']
    assert_equal 'failure', last_status(reject_tx)['state']
  end

  # --- fail-closed paths -------------------------------------------------

  def test_oversized_diff_fails_closed_without_calling_model
    big = 'x' * 300_000
    code, tx = run_engine({ 'MAX_DIFF_BYTES' => '200000' }, diff: big)
    assert_equal 1, code
    assert_equal 'failure', last_status(tx)['state']
    assert_includes last_status(tx)['description'], 'too large'
    assert_empty model_calls(tx), 'model must not be called on an oversized diff'
  end

  def test_empty_diff_fails_closed
    code, tx = run_engine({}, diff: "   \n  ")
    assert_equal 1, code
    assert_equal 'failure', last_status(tx)['state']
    assert_empty model_calls(tx)
  end

  def test_refusal_fails_closed
    code, tx = run_engine({}, anthropic_body: JSON.generate('stop_reason' => 'refusal', 'content' => []))
    assert_equal 1, code
    assert_equal 'failure', last_status(tx)['state']
  end

  def test_truncated_response_fails_closed
    body = JSON.generate('stop_reason' => 'max_tokens',
                         'content' => [{ 'type' => 'text', 'text' => '{"verdict":"APPR' }])
    code, tx = run_engine({}, anthropic_body: body)
    assert_equal 1, code
    assert_equal 'failure', last_status(tx)['state']
  end

  def test_unparseable_response_fails_closed
    body = JSON.generate('stop_reason' => 'end_turn',
                         'content' => [{ 'type' => 'text', 'text' => 'not json at all' }])
    code, tx = run_engine({}, anthropic_body: body)
    assert_equal 1, code
    assert_equal 'failure', last_status(tx)['state']
  end

  def test_unknown_verdict_fails_closed
    body = JSON.generate('stop_reason' => 'end_turn',
                         'content' => [{ 'type' => 'text', 'text' => '{"verdict":"MAYBE","summary":"","findings":[]}' }])
    code, tx = run_engine({}, anthropic_body: body)
    assert_equal 1, code
    assert_equal 'failure', last_status(tx)['state']
  end

  def test_anthropic_non_200_fails_closed
    code, tx = run_engine({}, anthropic_code: 500, anthropic_body: '{"error":"boom"}')
    assert_equal 1, code
    assert_equal 'failure', last_status(tx)['state']
  end

  def test_missing_env_exits_nonzero_without_status
    transport = FakeTransport.new(&responder)
    env = base_env.tap { |e| e.delete('ANTHROPIC_API_KEY') }
    code = CIReview::Engine.new(env, transport: transport).run
    assert_equal 1, code
    assert_empty status_posts(transport), 'no head sha resolved -> no status (absence blocks)'
  end

  # --- idempotency -------------------------------------------------------

  def test_skips_when_already_decided
    existing = [{ 'context' => 'opus-adversarial-review', 'state' => 'success' }]
    code, tx = run_engine({}, existing_statuses: existing, verdict: 'REQUEST_CHANGES')
    assert_equal 0, code
    assert_empty status_posts(tx), 'must not re-post on an already-decided head'
    assert_empty model_calls(tx), 'must not re-run the model on an already-decided head'
  end

  def test_does_not_skip_on_unrelated_existing_status
    existing = [{ 'context' => 'test', 'state' => 'success' }]
    code, tx = run_engine({}, existing_statuses: existing, verdict: 'APPROVE')
    assert_equal 0, code
    assert_equal 1, status_posts(tx).size
  end

  # --- misc guarantees ---------------------------------------------------

  def test_description_is_clamped_to_140_chars
    long = 'A' * 400
    _, tx = run_engine({}, verdict: 'APPROVE', summary: long)
    desc = last_status(tx)['description']
    assert_operator desc.length, :<=, 140
    assert desc.end_with?('...')
  end

  def test_request_asks_for_schema_constrained_verdict
    _, tx = run_engine({ 'REVIEW_MODEL' => 'claude-opus-5' }, verdict: 'APPROVE')
    body = JSON.parse(model_calls(tx).last[:body])
    assert_equal 'claude-opus-5', body['model']
    assert_equal 'json_schema', body.dig('output_config', 'format', 'type')
    assert_equal 'high', body.dig('output_config', 'effort')
    schema = body.dig('output_config', 'format', 'schema')
    assert_equal %w[APPROVE REQUEST_CHANGES], schema.dig('properties', 'verdict', 'enum')
    refute_empty body['system'].to_s, 'system prompt must be sent'
  end

  def test_diff_is_fetched_as_data_via_media_type
    _, tx = run_engine({}, verdict: 'APPROVE')
    diff_get = tx.requests.find do |r|
      r[:method] == :get && r[:uri].include?('/pulls/') &&
        r[:headers]['Accept'] == 'application/vnd.github.diff'
    end
    refute_nil diff_get, 'diff must be fetched through the .diff media type, never a checkout'
  end
end

# The claude-cli backend (local, Claude Code subscription) must post the SAME
# required status to the head SHA, so it gates merges identically to the API
# backend. It also must fail closed on every claude-cli failure mode and need no
# ANTHROPIC_API_KEY.
class ClaudeCliBackendTest < Minitest::Test
  include ReviewFixtures

  def test_approve_posts_success_without_api_key
    claude = FakeClaude.new(out: claude_envelope(verdict_json(verdict: 'APPROVE', summary: 'clean')))
    code, tx = run_engine_cli({}, {}, claude)
    assert_equal 0, code
    body = last_status(tx)
    assert_equal 'success', body['state']
    assert_equal 'opus-adversarial-review', body['context']
    assert_includes status_posts(tx).last[:uri], "/statuses/#{ReviewFixtures::HEAD_SHA}"
  end

  def test_request_changes_posts_failure
    claude = FakeClaude.new(out: claude_envelope(verdict_json(verdict: 'REQUEST_CHANGES', summary: 'bug')))
    code, tx = run_engine_cli({}, {}, claude)
    assert_equal 1, code
    assert_equal 'failure', last_status(tx)['state']
  end

  def test_is_error_envelope_fails_closed
    claude = FakeClaude.new(out: claude_envelope('OAuth token expired', is_error: true))
    code, tx = run_engine_cli({}, {}, claude)
    assert_equal 1, code
    assert_equal 'failure', last_status(tx)['state']
  end

  def test_nonzero_exit_fails_closed
    claude = FakeClaude.new(out: '', ok: false, err: 'claude not found')
    code, tx = run_engine_cli({}, {}, claude)
    assert_equal 1, code
    assert_equal 'failure', last_status(tx)['state']
  end

  def test_extracts_json_from_fenced_result
    fenced = "```json\n#{verdict_json(verdict: 'APPROVE')}\n```"
    claude = FakeClaude.new(out: claude_envelope(fenced))
    code, tx = run_engine_cli({}, {}, claude)
    assert_equal 0, code
    assert_equal 'success', last_status(tx)['state']
  end

  def test_extracts_json_from_surrounding_prose
    prose = "Here is my verdict:\n#{verdict_json(verdict: 'REQUEST_CHANGES', summary: 'x')}\nThanks."
    claude = FakeClaude.new(out: claude_envelope(prose))
    code, tx = run_engine_cli({}, {}, claude)
    assert_equal 1, code
    assert_equal 'failure', last_status(tx)['state']
  end

  def test_unparseable_result_fails_closed
    claude = FakeClaude.new(out: claude_envelope('no json here at all'))
    code, tx = run_engine_cli({}, {}, claude)
    assert_equal 1, code
    assert_equal 'failure', last_status(tx)['state']
  end

  def test_invokes_claude_headless_with_model
    claude = FakeClaude.new(out: claude_envelope(verdict_json(verdict: 'APPROVE')))
    run_engine_cli({ 'REVIEW_MODEL' => 'opus' }, {}, claude)
    argv = claude.calls.last[:argv]
    assert_includes argv, '-p'
    assert_includes argv, '--output-format'
    assert_includes argv, 'json'
    assert_equal 'opus', argv[argv.index('--model') + 1]
    # The diff must be handed to claude on stdin (as data), never as a checkout.
    assert_includes claude.calls.last[:stdin], '```diff'
  end

  def test_force_bypasses_already_decided
    existing = [{ 'context' => 'opus-adversarial-review', 'state' => 'failure' }]
    claude = FakeClaude.new(out: claude_envelope(verdict_json(verdict: 'APPROVE')))
    code, tx = run_engine_cli({ 'REVIEW_FORCE' => '1' }, { existing_statuses: existing }, claude)
    assert_equal 0, code
    assert_equal 1, status_posts(tx).size, 'REVIEW_FORCE must re-review and re-post'
    assert_equal 'success', last_status(tx)['state']
  end
end
