# frozen_string_literal: true

require_relative "lib/rubocop/harness/version"

Gem::Specification.new do |spec|
  spec.name = "rubocop-harness"
  spec.version = RuboCop::Harness::VERSION
  spec.authors = ["Ventro"]

  spec.summary = "Shared RuboCop cops enforcing the harness comment policy."
  spec.description = <<~DESC
    Custom RuboCop cops that enforce the mechanically decidable parts of the
    cross-app comment policy owned in harness-infra (rules/global-common.md,
    ## Comments): comment-block length, commented-out code, unreferenced
    TODO/FIXME annotations, decorative banners, and (opt-in) method narration.
  DESC
  spec.homepage = "https://github.com/d3vkit/harness-infra"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "#{spec.homepage}/tree/main/rubocop-harness"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*.rb", "config/default.yml", "README.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "rubocop", ">= 1.72", "< 2.0"
end
