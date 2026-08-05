# frozen_string_literal: true

module RuboCop
  module Harness
    # Merges this gem's config/default.yml into RuboCop's default configuration,
    # so an app that `require`s rubocop-harness gets the Harness/* cop defaults
    # without restating them. This is the same injection pattern the first-party
    # extensions (rubocop-performance, rubocop-rspec) use.
    module Inject
      def self.defaults!
        path = CONFIG_DEFAULT.to_s
        hash = RuboCop::ConfigLoader.send(:load_yaml_configuration, path)
        config = RuboCop::Config.new(hash, path)
        puts "configuration from #{path}" if RuboCop::ConfigLoader.debug?
        config = RuboCop::ConfigLoader.merge_with_default(config, path)
        RuboCop::ConfigLoader.instance_variable_set(:@default_configuration, config)
      end
    end
  end
end
