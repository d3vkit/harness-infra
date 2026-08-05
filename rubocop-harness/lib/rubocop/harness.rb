# frozen_string_literal: true

require "pathname"

module RuboCop
  # Namespace for the shared harness comment-policy cops.
  module Harness
    PROJECT_ROOT = Pathname.new(__dir__).join("..", "..").expand_path.freeze
    CONFIG_DEFAULT = PROJECT_ROOT.join("config", "default.yml").freeze
  end
end
