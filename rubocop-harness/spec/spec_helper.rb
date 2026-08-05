# frozen_string_literal: true

require "rubocop"
require "rubocop/rspec/support"
require "rubocop-harness"

RSpec.configure do |config|
  config.include RuboCop::RSpec::ExpectOffense

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed
end
