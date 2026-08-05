# frozen_string_literal: true

module RuboCop
  module Cop
    module Harness
      # Flags a run of consecutive standalone comment lines longer than `Max`.
      # A long inline block is usually rationale that belongs in a design doc,
      # where a documentation review catches drift; the code keeps a one-line
      # pointer instead.
      #
      # @example Max: 4 (default)
      #   # bad — a six-line essay wired into the code
      #   # line 1
      #   # line 2
      #   # line 3
      #   # line 4
      #   # line 5
      #   # line 6
      #
      #   # good — a pointer to where the rationale is reviewed and versioned
      #   # Lock-ordering invariant: see docs/design/billing-webhook-concurrency.md (VEN-1222).
      class CommentBlockLength < Base
        MSG = "Comment block is %<count>d lines (max %<max>d); move extended " \
              "rationale to a design doc and leave a one-line pointer."

        def on_new_investigation
          comment_blocks.each do |block|
            next if block.size <= max

            add_offense(
              block.first.source_range,
              message: format(MSG, count: block.size, max: max)
            )
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
          processed_source.comments.select do |comment|
            standalone?(comment) && !directive?(comment)
          end
        end

        def standalone?(comment)
          line = processed_source.lines[comment.source_range.line - 1]
          !line.nil? && line.lstrip.start_with?("#")
        end

        def directive?(comment)
          comment.text.match?(/\A#\s*rubocop:/)
        end

        def max
          cop_config.fetch("Max", 4)
        end
      end
    end
  end
end
