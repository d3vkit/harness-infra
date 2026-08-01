#!/usr/bin/env ruby
# frozen_string_literal: true

# ci-review/run_review.rb — CI adversarial-review engine (VEN-1526)
#
# Runs the `opus-adversarial-review` merge gate as a machine, not an agent.
# It fetches a pull request's diff *as data* (it never checks out or executes
# the PR's code), sends the diff to the Anthropic Messages API for a single
# structured adversarial review, maps the model's verdict to a GitHub commit
# status state, and POSTs `opus-adversarial-review` to the PR's HEAD commit.
#
# Design constraints (VEN-1526 — see docs/runbooks/ci-adversarial-review.md):
#
#   * FAIL CLOSED. `success` is posted ONLY when the HTTP call is 2xx AND the
#     response parses AND the verdict is APPROVE. Every other outcome posts
#     `failure`, or exits non-zero with no status at all. The Main ruleset
#     requires the status present AND success, so absence blocks a merge too.
#
#   * POST TO HEAD, NOT THE MERGE REF. On pull_request(_target) events the
#     workflow's github.sha is the throwaway refs/pull/N/merge commit; required
#     checks are evaluated on the PR *head*. We resolve head.sha via the API and
#     target that — mirroring script/post_review_status.sh's headRefOid usage.
#
#   * DIFF AS DATA. We read the diff through the GitHub `.diff` media type so no
#     head-controlled code ever lands on disk or executes. Combined with the
#     caller running under `pull_request_target` (base-defined workflow), the
#     review logic cannot be tampered with by the PR under review.
#
#   * IDEMPOTENT. An LLM verdict is nondeterministic and combined statuses are
#     last-write-wins per (context, SHA), so a re-run on an unchanged head could
#     flip a real failure to success. Opus 5 rejects `temperature`, so we cannot
#     pin determinism that way; instead we skip entirely if this context already
#     has a status on the head SHA. A new head SHA gets a fresh review.
#
# Pure Ruby stdlib (net/http + json + uri) — runs on ubuntu-latest's
# preinstalled Ruby with no gems. The engine lives in the harness repo, not in
# the app under review, so a PR cannot rewrite its own gate.
#
# Required env:
#   GITHUB_REPOSITORY  owner/repo of the PR
#   PR_NUMBER          pull request number
#   GITHUB_TOKEN       token with statuses:write + pull-requests:read
#   ANTHROPIC_API_KEY  Anthropic API key
#
# Optional env (defaults in brackets):
#   GITHUB_API_URL     [https://api.github.com]
#   ANTHROPIC_API_URL  [https://api.anthropic.com]
#   REVIEW_MODEL       [claude-opus-5]
#   REVIEW_EFFORT      [high]      one of low|medium|high|xhigh|max
#   STATUS_CONTEXT     [opus-adversarial-review]
#   MAX_DIFF_BYTES     [200000]    oversized diff -> fail closed, never truncate
#   MAX_TOKENS         [8000]      caps thinking + output; keep generous
#   HTTP_TIMEOUT       [900]       per-request read timeout, seconds
#   PROMPT_PATH        [<script dir>/prompt.md]
#   TARGET_URL         [PR html_url] link surfaced on the status

require 'net/http'
require 'json'
require 'uri'

module CIReview
  ANTHROPIC_VERSION = '2023-06-01'

  # A finding schema kept intentionally simple: structured outputs forbid
  # string-length / numeric constraints, so we only lean on type + enum.
  VERDICT_SCHEMA = {
    'type' => 'object',
    'additionalProperties' => false,
    'required' => %w[verdict summary findings],
    'properties' => {
      'verdict' => { 'type' => 'string', 'enum' => %w[APPROVE REQUEST_CHANGES] },
      'summary' => { 'type' => 'string' },
      'findings' => {
        'type' => 'array',
        'items' => {
          'type' => 'object',
          'additionalProperties' => false,
          'required' => %w[severity title file description],
          'properties' => {
            'severity' => { 'type' => 'string', 'enum' => %w[blocker high medium low nit] },
            'title' => { 'type' => 'string' },
            'file' => { 'type' => 'string' },
            'line' => { 'type' => 'integer' },
            'description' => { 'type' => 'string' }
          }
        }
      }
    }
  }.freeze

  # Raised for any condition that must post `failure` (a definite negative
  # verdict we can attribute) rather than simply exit with no status.
  class ReviewFailure < StandardError; end

  # Real HTTP transport. Extracted behind a seam so the engine can be unit
  # tested with a fake transport and no network. Returns [status_code, body].
  class NetHTTPTransport
    def call(method, uri, headers, body, timeout)
      req = (method == :post ? Net::HTTP::Post : Net::HTTP::Get).new(uri)
      headers.each { |k, v| req[k] = v }
      req.body = body if body

      res = Net::HTTP.start(uri.host, uri.port,
                            use_ssl: uri.scheme == 'https',
                            open_timeout: 30, read_timeout: timeout) do |h|
        h.request(req)
      end
      [res.code.to_i, res.body.to_s]
    end
  end

  class Engine
    def initialize(env = ENV, transport: NetHTTPTransport.new)
      @env = env
      @transport = transport
      # Only non-required config is read here; required vars are validated inside
      # #run so a missing one fails closed (returns non-zero) rather than raising
      # from the constructor.
      @gh_api      = env.fetch('GITHUB_API_URL', 'https://api.github.com')
      @anthropic   = env.fetch('ANTHROPIC_API_URL', 'https://api.anthropic.com')
      @model       = env.fetch('REVIEW_MODEL', 'claude-opus-5')
      @effort      = env.fetch('REVIEW_EFFORT', 'high')
      @context     = env.fetch('STATUS_CONTEXT', 'opus-adversarial-review')
      @max_diff    = Integer(env.fetch('MAX_DIFF_BYTES', '200000'))
      @max_tokens  = Integer(env.fetch('MAX_TOKENS', '8000'))
      @timeout     = Integer(env.fetch('HTTP_TIMEOUT', '900'))
      @prompt_path = env.fetch('PROMPT_PATH', File.join(__dir__, 'prompt.md'))
      @explicit_target = env['TARGET_URL']
    end

    # Returns a process exit status. Guarantees: `success` is posted on exactly
    # one path (APPROVE). Anything attributable posts `failure`; anything that
    # prevents even resolving the head SHA exits non-zero with no status (which
    # the ruleset also treats as blocking).
    def run
      read_required!
      pr = fetch_pull_request
      @head_sha   = pr.fetch('head').fetch('sha')
      @target_url = @explicit_target || pr['html_url'] || "https://github.com/#{@repo}/pull/#{@pr}"

      if already_decided?(@head_sha)
        log "status '#{@context}' already present on #{short(@head_sha)} — skipping (idempotent)"
        return 0
      end

      diff = fetch_diff
      if diff.bytesize > @max_diff
        # Truncating could hide the offending hunk and yield a false APPROVE.
        post_status('failure', "diff too large for automated review (#{diff.bytesize} bytes)")
        warn "diff #{diff.bytesize}B exceeds MAX_DIFF_BYTES=#{@max_diff} — failing closed"
        return 1
      end
      if diff.strip.empty?
        post_status('failure', 'empty diff — nothing to review')
        return 1
      end

      review = review_diff(diff)
      verdict = review['verdict']
      summary = clamp_description(review['summary'].to_s)

      if verdict == 'APPROVE'
        post_status('success', summary.empty? ? 'Adversarial review passed' : summary)
        log "APPROVE — posted success on #{short(@head_sha)}"
        0
      else
        post_status('failure', summary.empty? ? 'Adversarial review requested changes' : summary)
        warn "REQUEST_CHANGES — posted failure on #{short(@head_sha)}"
        log "findings: #{review['findings'].inspect}"
        1
      end
    rescue ReviewFailure => e
      # Attributable failure: we know the head SHA, post an explicit failure.
      if @head_sha
        post_status('failure', clamp_description("review error: #{e.message}"))
        warn "review failed closed on #{short(@head_sha)}: #{e.message}"
      else
        warn "review failed before head SHA was resolved: #{e.message} — no status posted (absence blocks)"
      end
      1
    rescue StandardError => e
      # Any unexpected error also fails closed.
      if @head_sha
        post_status('failure', clamp_description("unexpected error: #{e.class}"))
        warn "unexpected error, failed closed on #{short(@head_sha)}: #{e.class}: #{e.message}"
      else
        warn "unexpected error before head SHA resolved: #{e.class}: #{e.message} — no status posted"
      end
      1
    end

    private

    def read_required!
      @repo     = require_env(@env, 'GITHUB_REPOSITORY')
      @pr       = require_env(@env, 'PR_NUMBER')
      @gh_token = require_env(@env, 'GITHUB_TOKEN')
      @api_key  = require_env(@env, 'ANTHROPIC_API_KEY')
    end

    # --- GitHub -----------------------------------------------------------

    def fetch_pull_request
      code, body = github_get("/repos/#{@repo}/pulls/#{@pr}")
      raise ReviewFailure, "GitHub PR fetch returned #{code}" unless code == 200

      JSON.parse(body)
    end

    def already_decided?(sha)
      # Combined statuses for the head commit; skip if our context is present.
      code, body = github_get("/repos/#{@repo}/commits/#{sha}/statuses?per_page=100")
      return false unless code == 200

      JSON.parse(body).any? { |s| s['context'] == @context }
    rescue StandardError
      # If we cannot read prior statuses, do NOT skip — proceed to review.
      false
    end

    def fetch_diff
      code, body = github_get("/repos/#{@repo}/pulls/#{@pr}", accept: 'application/vnd.github.diff')
      raise ReviewFailure, "GitHub diff fetch returned #{code}" unless code == 200

      # The diff arrives as binary bytes; force to UTF-8 and scrub any invalid
      # sequences so the API request body is always valid JSON-serializable UTF-8.
      body.dup.force_encoding('UTF-8').scrub('?')
    end

    def post_status(state, description)
      payload = {
        'state' => state,
        'context' => @context,
        'description' => clamp_description(description)
      }
      payload['target_url'] = @target_url if @target_url
      code, body = github_post("/repos/#{@repo}/statuses/#{@head_sha}", payload)
      return if code == 201

      # A failed status POST on the success path would leave the gate un-set
      # (which blocks) — surface it loudly but do not crash the fail path.
      warn "status POST returned #{code}: #{body}"
    end

    def github_get(path, accept: 'application/vnd.github+json')
      http(:get, URI.join(@gh_api + '/', path.sub(%r{\A/}, '')), github_headers(accept))
    end

    def github_post(path, payload)
      http(:post, URI.join(@gh_api + '/', path.sub(%r{\A/}, '')),
           github_headers('application/vnd.github+json'), JSON.generate(payload))
    end

    def github_headers(accept)
      {
        'Authorization' => "Bearer #{@gh_token}",
        'Accept' => accept,
        'X-GitHub-Api-Version' => '2022-11-28',
        'User-Agent' => 'harness-ci-adversarial-review'
      }
    end

    # --- Anthropic --------------------------------------------------------

    def review_diff(diff)
      body = {
        'model' => @model,
        'max_tokens' => @max_tokens,
        'output_config' => {
          'effort' => @effort,
          'format' => { 'type' => 'json_schema', 'schema' => VERDICT_SCHEMA }
        },
        'system' => prompt_text,
        'messages' => [
          { 'role' => 'user',
            'content' => "Review this pull request diff and return your structured verdict.\n\n" \
                         "```diff\n#{diff}\n```" }
        ]
      }
      code, raw = http(:post, URI.join(@anthropic + '/', 'v1/messages'), anthropic_headers, JSON.generate(body))
      raise ReviewFailure, "Anthropic API returned #{code}: #{truncate(raw, 400)}" unless code == 200

      parse_review(raw)
    end

    def parse_review(raw)
      resp = JSON.parse(raw)
      stop = resp['stop_reason']
      raise ReviewFailure, 'model refused the request' if stop == 'refusal'
      raise ReviewFailure, 'response truncated (max_tokens) — inconclusive' if stop == 'max_tokens'

      text = Array(resp['content'])
             .select { |b| b['type'] == 'text' }
             .map { |b| b['text'] }
             .join
      raise ReviewFailure, 'empty model response' if text.strip.empty?

      review = JSON.parse(text)
      unless %w[APPROVE REQUEST_CHANGES].include?(review['verdict'])
        raise ReviewFailure, "unrecognized verdict: #{review['verdict'].inspect}"
      end

      review['findings'] ||= []
      review
    rescue JSON::ParserError => e
      raise ReviewFailure, "unparseable model response: #{e.message}"
    end

    def anthropic_headers
      {
        'x-api-key' => @api_key,
        'anthropic-version' => ANTHROPIC_VERSION,
        'content-type' => 'application/json'
      }
    end

    def prompt_text
      @prompt_text ||= File.read(@prompt_path, encoding: 'UTF-8')
    rescue StandardError => e
      raise ReviewFailure, "cannot read prompt at #{@prompt_path}: #{e.message}"
    end

    # --- HTTP -------------------------------------------------------------

    def http(method, uri, headers, body = nil)
      @transport.call(method, uri, headers, body, @timeout)
    rescue StandardError => e
      # Network/timeout failures are surfaced as a ReviewFailure so the caller
      # fails closed rather than crashing.
      raise ReviewFailure, "HTTP #{method} #{uri.host} failed: #{e.class}: #{e.message}"
    end

    # --- helpers ----------------------------------------------------------

    def require_env(env, key)
      v = env[key]
      raise ReviewFailure, "missing required env #{key}" if v.nil? || v.empty?

      v
    end

    # GitHub commit-status descriptions are capped at 140 chars.
    def clamp_description(str)
      s = str.to_s.gsub(/\s+/, ' ').strip
      s.length > 140 ? "#{s[0, 137]}..." : s
    end

    def truncate(str, n)
      str.to_s.length > n ? "#{str[0, n]}..." : str.to_s
    end

    def short(sha)
      sha.to_s[0, 8]
    end

    def log(msg)
      warn "[ci-review] #{msg}"
    end
  end
end

exit(CIReview::Engine.new.run) if $PROGRAM_NAME == __FILE__
