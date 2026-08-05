# frozen_string_literal: true

module RuboCop
  module Cop
    module Harness
      # Flags a lone comment directly above a method definition that only
      # narrates what the method does — `# Returns the user` above `def user`.
      # Such a comment restates the signature and drifts; a constraint or a
      # non-obvious "why" would earn its place, plain narration does not.
      #
      # High false-positive risk (a narration verb can open a legitimate note),
      # so this cop is disabled by default; enable it per app once a burn-down
      # confirms the hit rate.
      #
      # @example
      #   # bad
      #   # Returns the current user
      #   def current_user; end
      #
      #   # good — states a constraint, not narration
      #   # Callers must hold the row lock; see docs/design/....
      #   def current_user; end
      class NarrationComment < Base
        MSG = "Comment only narrates what the method does; delete it or state a constraint."

        DEFAULT_VERBS = %w[
          Returns Return Sets Set Builds Build Fetches Fetch Creates Create
          Gets Get Adds Add Removes Remove Checks Check Updates Update
          Handles Handle Wraps Wrap
        ].freeze

        def on_def(node)
          comment = lone_preceding_comment(node)
          return unless comment
          return unless narration?(comment.text)

          add_offense(comment.source_range, message: MSG)
        end
        alias on_defs on_def

        private

        # The comment immediately above the def, but only when it stands alone —
        # a longer block above is not simple narration and is left to
        # CommentBlockLength.
        def lone_preceding_comment(node)
          def_line = node.source_range.line
          comment = comment_on_line(def_line - 1)
          return nil unless comment && standalone?(comment)
          return nil if comment_on_line(def_line - 2) # part of a block

          comment
        end

        def comment_on_line(line)
          processed_source.comments.find { |c| c.source_range.line == line }
        end

        def standalone?(comment)
          line = processed_source.lines[comment.source_range.line - 1]
          !line.nil? && line.lstrip.start_with?("#")
        end

        def narration?(text)
          body = text.sub(/\A#+\s*/, "")
          body.match?(/\A(#{verbs.map { |v| Regexp.escape(v) }.join('|')})\b/)
        end

        def verbs
          cop_config.fetch("Verbs", DEFAULT_VERBS)
        end
      end
    end
  end
end
