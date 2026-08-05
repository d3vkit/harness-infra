# frozen_string_literal: true

module RuboCop
  module Cop
    module Harness
      # Requires every TODO/FIXME/HACK-style annotation to carry a tracker
      # ticket reference (e.g. `VEN-1234`). An annotation without a ticket is
      # either untracked work or stale; both should be resolved, not left in the
      # code as an orphan.
      #
      # This is distinct from Style/CommentAnnotation, which checks the
      # annotation's *format* (keyword, colon, spacing) and not whether it points
      # at a ticket.
      #
      # @example TicketPattern: '[A-Z]{2,}-\d+' (default)
      #   # bad
      #   # TODO: handle the retry case
      #
      #   # good
      #   # TODO(VEN-1234): handle the retry case
      class AnnotationTicketRef < Base
        MSG = "%<keyword>s must reference a tracker ticket (matching /%<pattern>s/)."

        def on_new_investigation
          processed_source.comments.each do |comment|
            keyword = keyword_in(comment.text)
            next unless keyword
            next if comment.text.match?(ticket_regexp)

            add_offense(
              comment.source_range,
              message: format(MSG, keyword: keyword, pattern: ticket_pattern)
            )
          end
        end

        private

        def keyword_in(text)
          keywords.find { |kw| text.match?(/(?<![A-Za-z])#{Regexp.escape(kw)}(?![A-Za-z])/) }
        end

        def keywords
          cop_config.fetch("Keywords", %w[TODO FIXME HACK XXX OPTIMIZE])
        end

        def ticket_pattern
          cop_config.fetch("TicketPattern", '[A-Z]{2,}-\d+')
        end

        def ticket_regexp
          @ticket_regexp ||= Regexp.new(ticket_pattern)
        end
      end
    end
  end
end
