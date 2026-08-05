# frozen_string_literal: true

require "rubocop"

require_relative "rubocop/harness"
require_relative "rubocop/harness/version"
require_relative "rubocop/harness/inject"

RuboCop::Harness::Inject.defaults!

require_relative "rubocop/cop/harness/comment_block_length"
require_relative "rubocop/cop/harness/commented_out_code"
require_relative "rubocop/cop/harness/annotation_ticket_ref"
require_relative "rubocop/cop/harness/banner_comment"
require_relative "rubocop/cop/harness/narration_comment"
