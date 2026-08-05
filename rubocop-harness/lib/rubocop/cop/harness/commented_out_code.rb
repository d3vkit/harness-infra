# frozen_string_literal: true

module RuboCop
  module Cop
    module Harness
      # Flags commented-out code. Version control already preserves old code, so
      # a commented-out block is dead weight that misleads readers.
      #
      # Detecting code vs prose is heuristic, and this cop is deliberately
      # conservative — it errs toward missing some commented code rather than
      # flagging prose. A comment block is reported only when, after stripping the
      # leading `#`, it is valid Ruby AND its syntax tree contains a genuinely
      # structural node (an assignment, def/class/module, a block) or a
      # dot-method call on a solid receiver (a constant, ivar, or self). Prose
      # that happens to parse — `e.g. the user`, `per-subscription`, a file path,
      # a `delete it if stale` modifier — is left alone.
      #
      # Deliberately-indented usage examples (`#   User.find(id)`) are skipped
      # when `AllowIndentedExamples` is true.
      #
      # @example
      #   # bad
      #   # user = User.find(id)
      #   # user.deactivate!
      #
      #   # good (prose)
      #   # Deactivate the user found for this request.
      #
      #   # good (allowed usage example)
      #   # Usage:
      #   #   User.find(id).deactivate!
      class CommentedOutCode < Base
        MSG = "Commented-out code should be deleted; version control preserves it."

        DIRECTIVE = /\A#\s*(rubocop:|frozen_string_literal:|encoding:|coding:|warn_indent:|shareable_constant_value:)/
        SHEBANG = /\A#!/
        YARD_TAG = /\A#\s*@\w+/

        # AST node types that mark a comment as real code rather than prose.
        # `if/while/until/case` are intentionally excluded: a modifier form
        # ("delete it if stale") is ordinary prose that parses to an `if` node.
        STRUCTURAL_TYPES = %i[
          def defs class module sclass
          lvasgn ivasgn gvasgn cvasgn casgn masgn op_asgn or_asgn and_asgn
          block numblock
        ].freeze

        SOLID_RECEIVER_TYPES = %i[const ivar gvar cvar self str dstr sym array hash int float].freeze

        def on_new_investigation
          comment_blocks.each do |block|
            next if allowlisted?(block)
            next unless looks_like_code?(strip_block(block))

            add_offense(block.first.source_range, message: MSG)
          end
        end

        private

        # Maximal runs of consecutive standalone comment lines.
        def comment_blocks
          blocks = []
          current = []
          standalone_comments.each do |comment|
            line = comment.source_range.line
            if current.empty? || line == current.last.source_range.line + 1
              current << comment
            else
              blocks << current
              current = [comment]
            end
          end
          blocks << current unless current.empty?
          blocks
        end

        def standalone_comments
          processed_source.comments.select { |comment| standalone?(comment) }
        end

        def standalone?(comment)
          line = processed_source.lines[comment.source_range.line - 1]
          !line.nil? && line.lstrip.start_with?("#")
        end

        def allowlisted?(block)
          texts = block.map(&:text)
          return true if texts.any? { |t| t.match?(DIRECTIVE) || t.match?(SHEBANG) || t.match?(YARD_TAG) }
          return true if allowed_patterns.any? { |re| texts.any? { |t| re.match?(t) } }
          return true if allow_indented_examples? && labeled_example?(block)

          false
        end

        # A usage example — indented code introduced by a non-code header line
        # (a prose line ending in `:`, or one that says "example"/"usage"). This
        # distinguishes `# Usage:\n#   User.find(id)` (skip) from a commented-out
        # method body `# def call\n#   x = 1\n# end` (flag), whose lines are also
        # indented but which has no prose header.
        def labeled_example?(block)
          return false unless block.any? { |c| indented_example?(c.text) }

          block.any? { |c| !indented_example?(c.text) && example_header?(c.text) }
        end

        def indented_example?(text)
          text.match?(/\A#\s{2,}\S/)
        end

        def example_header?(text)
          body = text.sub(/\A#+\s*/, "").rstrip
          body.end_with?(":") || body.match?(/\b(example|usage|e\.g\.|for instance|such as)\b/i)
        end

        # Strip the comment marker and at most one following space, so relative
        # indentation of a multi-line block is preserved for parsing.
        def strip_block(block)
          block.map { |comment| comment.text.sub(/\A#/, "").sub(/\A /, "") }.join("\n")
        end

        def looks_like_code?(text)
          return false if text.strip.empty?

          source = RuboCop::ProcessedSource.new(text, target_ruby_version)
          return false unless source.valid_syntax?

          ast = source.ast
          !ast.nil? && structural?(ast)
        rescue StandardError
          false
        end

        def structural?(node)
          return false unless node.is_a?(RuboCop::AST::Node)
          return true if STRUCTURAL_TYPES.include?(node.type)
          return true if solid_dot_call?(node)

          node.each_child_node.any? { |child| structural?(child) }
        end

        # A `.`-method call whose receiver chain bottoms out in something
        # concrete (`User.find`, `@user.save`, `self.reload`) — the signature of
        # commented-out code, not of prose.
        def solid_dot_call?(node)
          return false unless node.type == :send
          return false unless dot?(node)
          # Skip the `.()` call shorthand, which carries no explicit selector.
          # In a comment it is almost always prose punctuation, not a call:
          # "skip the HGET. (VEN-1038)" parses as `HGET.(VEN - 1038)`.
          return false if node.method_name == :call && node.loc.selector.nil?

          solid_receiver?(node.receiver)
        end

        def solid_receiver?(node)
          return false unless node.is_a?(RuboCop::AST::Node)
          return true if SOLID_RECEIVER_TYPES.include?(node.type)
          return solid_receiver?(node.receiver) if node.type == :send && dot?(node)

          false
        end

        def dot?(node)
          node.loc.respond_to?(:dot) && !node.loc.dot.nil?
        end

        def allow_indented_examples?
          cop_config.fetch("AllowIndentedExamples", true)
        end

        def allowed_patterns
          @allowed_patterns ||= Array(cop_config["AllowedPatterns"]).map { |p| Regexp.new(p) }
        end
      end
    end
  end
end
