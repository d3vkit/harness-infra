# frozen_string_literal: true

# Deliberately defective fixture for the check_ruby26_syntax.sh self-test. Do NOT "fix" it.
#
# This reproduces the original VEN-1321 defect verbatim in shape: Ruby 3.1 shorthand hash
# syntax, which parses fine on 3.x (so the 3.3 `ruby -c` CI step calls it clean) and fails at
# *parse* time on macOS's system Ruby 2.6. A checker that cannot go red on this file proves
# nothing, so CI asserts both directions — clean on script/*.rb, non-zero here.

def graphql(query, variables)
  { query:, variables: }
end
