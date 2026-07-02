#!/usr/bin/env ruby
# frozen_string_literal: true

# Archives Done (completed-state) Linear tickets when a board gets crowded.
#
# Lives in the shared agent-harness-infra repo so every sibling app uses ONE
# copy instead of a per-app fork hardcoded to its own team. By default it scans
# every team the API key can see; scope it to any team(s) and/or project(s) with
# the flags below.
#
# Scope (combine freely; default = every team in the workspace):
#   --team KEY         restrict to team(s) by key, repeatable (e.g. --team VEN --team WHA)
#   --project NAME|ID  restrict to Linear project(s) by name or UUID, repeatable
#
# Behavior:
#   (default)          per team: archive Done only when that team has >= --threshold
#                      Done tickets, keeping the --keep most recently completed
#   --all              ignore the threshold and keep; archive every Done in scope
#   --threshold N      crowded-board threshold, applied per team (default 50)
#   --keep N           most-recently-completed Done tickets to keep per team (default 5)
#   --dry-run          print what would be archived; make no changes
#   -h, --help         show this help
#
# Auth:
#   Reads LINEAR_API_KEY from the environment. If it isn't exported there (the
#   common case for agents, whose non-interactive shells don't source ~/.zshrc),
#   it falls back to asking your login shell for it — so a key exported in an
#   interactive rc like ~/.zshrc is picked up without a manual export.
#
# Usage:
#   LINEAR_API_KEY=lin_api_xxx ruby script/archive_done_linear_tickets.rb --dry-run
#   ruby script/archive_done_linear_tickets.rb --dry-run   # key read from ~/.zshrc
#   LINEAR_API_KEY=lin_api_xxx ruby script/archive_done_linear_tickets.rb            # all teams, crowded ones only
#   LINEAR_API_KEY=lin_api_xxx ruby script/archive_done_linear_tickets.rb --team WHA --all
#   LINEAR_API_KEY=lin_api_xxx ruby script/archive_done_linear_tickets.rb --project "Live Transcription" --all

require "net/http"
require "json"

USAGE = <<~TXT
  Archives Done (completed-state) Linear tickets when a board gets crowded.
  Scans every team by default; scope with --team and/or --project.

    --team KEY         restrict to team(s) by key, repeatable (e.g. --team VEN --team WHA)
    --project NAME|ID  restrict to Linear project(s) by name or UUID, repeatable
    --threshold N      crowded-board threshold, per team (default 50; ignored by --all)
    --keep N           most-recently-completed Done to keep per team (default 5; ignored by --all)
    --all              archive every Done in scope, ignoring --threshold and --keep
    --yes, -y          confirm --all when it has no --team/--project (whole-workspace)
    --dry-run          print what would be archived; make no changes
    -h, --help         show this help

  LINEAR_API_KEY must be resolvable: exported in the environment, or exported in
  your login shell rc (e.g. ~/.zshrc) — the script reads it from there when it is
  not already in the environment. Example:
    LINEAR_API_KEY=lin_api_xxx ruby script/archive_done_linear_tickets.rb --project "Live Transcription" --all --dry-run
TXT
UUID_RE = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

def parse_int(flag, str)
  Integer(str)
rescue ArgumentError
  abort("ERROR: #{flag} expects an integer, got #{str.inspect}")
end

def parse_args(argv)
  opts = { teams: [], projects: [], threshold: 50, keep: 5, all: false, dry_run: false, yes: false }
  i = 0
  while i < argv.length
    key, inline = argv[i].split("=", 2)
    value = lambda do
      if inline
        abort("ERROR: #{key} requires a non-empty value") if inline.empty?
        next inline
      end
      i += 1
      argv[i] or abort("ERROR: #{key} requires a value")
    end
    case key
    when "--team"      then opts[:teams] << value.call.upcase
    when "--project"   then opts[:projects] << value.call
    when "--threshold" then opts[:threshold] = parse_int(key, value.call)
    when "--keep"      then opts[:keep] = parse_int(key, value.call)
    when "--all"       then opts[:all] = true
    when "--yes", "-y" then opts[:yes] = true
    when "--dry-run"   then opts[:dry_run] = true
    when "-h", "--help" then puts(USAGE) || exit(0)
    else abort("ERROR: unknown argument #{argv[i]}\n\n#{USAGE}")
    end
    i += 1
  end
  opts
end

# Resolve LINEAR_API_KEY. Prefer the environment; if it's absent there, ask the
# user's login shell for it. Agents shell out through non-interactive shells that
# don't source interactive rc files (~/.zshrc, ~/.bashrc), so a key exported only
# there is invisible to ENV — this fallback surfaces it without a manual export.
def resolve_api_key
  env = ENV["LINEAR_API_KEY"]
  return env unless env.nil? || env.strip.empty?

  shell = ENV["SHELL"]
  return nil unless shell && File.executable?(shell)

  key = key_from_login_shell(shell)
  return nil if key.nil? || key.empty?

  # A Linear API key contains no whitespace. If the login shell's rc still leaked
  # output around the value, refuse it instead of handing a poisoned string to
  # Net::HTTP (a CR/LF in the Authorization header raises) — fall through to the
  # clean "not found" abort rather than crash.
  if key.match?(/\s/)
    warn "[warn] ignoring LINEAR_API_KEY from login shell: value looks malformed (contains whitespace)."
    return nil
  end

  warn "[info] LINEAR_API_KEY not in environment; loaded it from your login shell (#{shell})."
  key
end

# Ask an interactive login shell to print $LINEAR_API_KEY on a dedicated fd (3),
# with the shell's own stdout and stderr discarded. Routing the value through fd 3
# rather than stdout keeps rc banner/prompt output (Powerlevel10k, nvm/rbenv
# greetings, an MOTD, a bare `echo`) from being captured as part of the key. stdin
# is /dev/null so an rc that reads input can never block. -l/-i source the login
# and interactive rc files (~/.zprofile, ~/.zshrc / ~/.bashrc) where the key lives.
def key_from_login_shell(shell)
  reader, writer = IO.pipe
  pid = Process.spawn(
    shell, "-lic", 'printf %s "$LINEAR_API_KEY" >&3',
    3 => writer, in: File::NULL, out: File::NULL, err: File::NULL
  )
  writer.close
  key = reader.read
  Process.wait(pid)
  key.to_s.strip
rescue SystemCallError => e
  warn "[warn] could not query #{shell} for LINEAR_API_KEY: #{e.message}"
  nil
ensure
  reader&.close
  writer&.close
end

def graphql(api_key, query, variables = {})
  uri = URI("https://api.linear.app/graphql")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true

  attempts = 0
  loop do
    attempts += 1
    req = Net::HTTP::Post.new(uri.path, "Content-Type" => "application/json", "Authorization" => api_key)
    req.body = JSON.generate({ query:, variables: })
    res = http.request(req)

    # Retry Linear rate limiting / transient 5xx a few times with linear backoff,
    # then surface a clear error rather than falling through to parse the error body.
    if %w[429 500 502 503 504].include?(res.code)
      raise "Linear HTTP #{res.code} after #{attempts} attempts: #{res.body.to_s[0, 200]}" if attempts > 5
      sleep(attempts * 1.0)
      next
    end

    data = JSON.parse(res.body)
    raise "Linear error: #{data["errors"].map { |e| e["message"] }.join(", ")}" if data["errors"]
    return data["data"]
  end
end

# Resolve --project NAME|ID args to project ids (names matched case-insensitively).
def resolve_project_ids(api_key, project_args)
  return [] if project_args.empty?

  wanted_ids   = project_args.select { |p| p.match?(UUID_RE) }
  wanted_names = project_args.reject { |p| p.match?(UUID_RE) }.map(&:downcase)
  return wanted_ids if wanted_names.empty?

  by_name = {}
  cursor = nil
  loop do
    page = graphql(api_key, <<~GQL, { after: cursor })["projects"]
      query($after: String) {
        projects(first: 250, after: $after) {
          pageInfo { hasNextPage endCursor }
          nodes { id name }
        }
      }
    GQL
    page["nodes"].each { |n| by_name[n["name"].downcase] = n["id"] }
    break unless page.dig("pageInfo", "hasNextPage")
    cursor = page.dig("pageInfo", "endCursor")
  end

  resolved = wanted_names.map do |name|
    by_name[name] || abort("ERROR: no Linear project named #{name.inspect} (matched case-insensitively)")
  end
  wanted_ids + resolved
end

FETCH_QUERY = <<~GQL
  query($filter: IssueFilter, $after: String) {
    issues(filter: $filter, first: 100, after: $after, orderBy: updatedAt) {
      pageInfo { hasNextPage endCursor }
      nodes { id identifier title completedAt team { key name } }
    }
  }
GQL

ARCHIVE_MUTATION = "mutation($id: String!) { issueArchive(id: $id) { success } }"

opts = parse_args(ARGV)
api_key = resolve_api_key or abort(<<~MSG)
  ERROR: LINEAR_API_KEY not found.
  Set it in the environment (export LINEAR_API_KEY=lin_api_...) or export it in your
  login shell rc (e.g. ~/.zshrc) so the script can read it. Create a key at
  https://linear.app/settings/api
MSG

puts "[dry-run] no changes will be made" if opts[:dry_run]

project_ids = resolve_project_ids(api_key, opts[:projects])

# Guard against an accidental whole-workspace wipe: --all with no scope would
# archive every Done ticket in every team. Require an explicit opt-in.
if opts[:all] && opts[:teams].empty? && project_ids.empty? && !opts[:dry_run] && !opts[:yes]
  abort <<~MSG
    ERROR: --all with no --team/--project would archive EVERY Done ticket in the whole workspace.
    Re-run with --dry-run to preview, scope it with --team/--project, or pass --yes to confirm.
  MSG
end

filter = { state: { type: { eq: "completed" } } }
filter[:team]    = { key: { in: opts[:teams] } } if opts[:teams].any?
filter[:project] = { id: { in: project_ids } }   if project_ids.any?

scope = []
scope << "teams #{opts[:teams].join(", ")}" if opts[:teams].any?
scope << "projects #{opts[:projects].join(", ")}" if opts[:projects].any?
puts "Scope: #{scope.empty? ? "all teams in the workspace" : scope.join(" | ")}"

# Fetch all Done tickets in scope.
tickets = []
cursor = nil
loop do
  page = graphql(api_key, FETCH_QUERY, { filter:, after: cursor })["issues"]
  tickets.concat(page["nodes"])
  print "\rFetched #{tickets.size} Done tickets..."
  $stdout.flush
  break unless page.dig("pageInfo", "hasNextPage")
  cursor = page.dig("pageInfo", "endCursor")
  sleep 0.2
end
puts
puts "Found #{tickets.size} Done tickets in scope.\n\n"

# Decide what to archive, grouped per team (so a crowded team doesn't nuke a
# quiet team's recent history, and --keep is honored per team).
to_archive = []
tickets.group_by { |t| t.dig("team", "key") }.sort.each do |team_key, group|
  team_name = group.first.dig("team", "name")
  group.sort_by! { |t| t["completedAt"] || "" }.reverse! # most-recently-completed first

  if opts[:all]
    picked = group
    reason = "--all"
  elsif group.size < opts[:threshold]
    puts "  #{team_key} (#{team_name}): #{group.size} Done - below threshold of #{opts[:threshold]}, skipping."
    next
  else
    picked = group[opts[:keep]..] || []
    reason = "keeping #{opts[:keep]} most recent"
  end

  puts "  #{team_key} (#{team_name}): #{group.size} Done -> archiving #{picked.size} (#{reason})."
  to_archive.concat(picked)
end

if to_archive.empty?
  puts "\nNothing to archive."
  exit 0
end

puts "\nArchiving #{to_archive.size} tickets...\n\n"
succeeded = 0
failed    = 0

to_archive.each_with_index do |t, i|
  print "\r[#{i + 1}/#{to_archive.size}] #{t["identifier"]} - #{t["title"].to_s[0, 60]}"
  $stdout.flush

  if opts[:dry_run]
    succeeded += 1
    next
  end

  begin
    graphql(api_key, ARCHIVE_MUTATION, { id: t["id"] })
    succeeded += 1
    sleep 0.2
  rescue => e
    failed += 1
    puts "\n  ERROR #{t["identifier"]}: #{e.message}"
  end
end

puts "\n\nDone. Archived: #{succeeded} | Failed: #{failed}#{" (dry-run)" if opts[:dry_run]}"
