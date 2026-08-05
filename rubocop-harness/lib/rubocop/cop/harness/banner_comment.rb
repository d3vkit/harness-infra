# frozen_string_literal: true

module RuboCop
  module Cop
    module Harness
      # Flags decorative divider banners — a comment whose body is a run of a
      # single punctuation character (`# ====`, `# ----`, `#########`). They
      # carry no information the code does not already convey through structure.
      #
      # @example
      #   # bad
      #   # ============================
      #   def call; end
      #
      #   # good
      #   def call; end
      class BannerComment < Base
        MSG = "Decorative divider banner carries no information; remove it."

        def on_new_investigation
          processed_source.comments.each do |comment|
            add_offense(comment.source_range, message: MSG) if banner?(comment.text)
          end
        end

        private

        def banner?(text)
          body = text.sub(/\A#+/, "").strip
          return false if body.empty?

          body.match?(/\A([-=*~#_])\1{#{min_repeat - 1},}\z/)
        end

        def min_repeat
          cop_config.fetch("MinRepeat", 4)
        end
      end
    end
  end
end
