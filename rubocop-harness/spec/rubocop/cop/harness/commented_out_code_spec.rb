# frozen_string_literal: true

require "spec_helper"

RSpec.describe RuboCop::Cop::Harness::CommentedOutCode, :config do
  it "flags a commented-out assignment" do
    expect_offense(<<~RUBY)
      # user = User.find(id)
      ^^^^^^^^^^^^^^^^^^^^^^ Commented-out code should be deleted; version control preserves it.
      run
    RUBY
  end

  it "flags a commented-out method body across lines" do
    expect_offense(<<~RUBY)
      # def call
      ^^^^^^^^^^ Commented-out code should be deleted; version control preserves it.
      #   User.find(id)
      # end
      run
    RUBY
  end

  it "flags a commented-out dot call on a constant receiver" do
    expect_offense(<<~RUBY)
      # User.where(active: true).count
      ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ Commented-out code should be deleted; version control preserves it.
      run
    RUBY
  end

  it "accepts ordinary prose" do
    expect_no_offenses(<<~RUBY)
      # Deactivate the user found for this request.
      run
    RUBY
  end

  it "accepts prose that happens to parse as Ruby" do
    expect_no_offenses(<<~RUBY)
      # See e.g. the user record for details.
      # Take the per-subscription row lock here.
      # Point at docs/design/foo.md for the rationale.
      # Delete it if stale.
      run
    RUBY
  end

  it "accepts prose where a constant abuts a parenthetical (the .() shorthand trap)" do
    expect_no_offenses(<<~RUBY)
      # We just wrote the flag; later calls skip the HGET. (VEN-1038)
      run
    RUBY
  end

  it "accepts a labeled, indented usage example" do
    expect_no_offenses(<<~RUBY)
      # Usage:
      #   User.find(id).deactivate!
      run
    RUBY
  end

  it "accepts a colon-headed example block like the provider base classes" do
    expect_no_offenses(<<~RUBY)
      # Concrete adapters subclass this:
      #
      #   class MyProvider::Adapter < TranscriptionProviders::BaseAdapter
      #     def provider_name = "MyProvider"
      #   end
      run
    RUBY
  end

  it "accepts a YARD example tag block" do
    expect_no_offenses(<<~RUBY)
      # @example
      #   User.find(id)
      run
    RUBY
  end
end
