# frozen_string_literal: true

require "spec_helper"

RSpec.describe RuboCop::Cop::Harness::NarrationComment, :config do
  it "flags a narration comment directly above a method" do
    expect_offense(<<~RUBY)
      # Returns the current user
      ^^^^^^^^^^^^^^^^^^^^^^^^^^ Comment only narrates what the method does; delete it or state a constraint.
      def current_user; end
    RUBY
  end

  it "flags narration above a singleton method" do
    expect_offense(<<~RUBY)
      # Builds the payload
      ^^^^^^^^^^^^^^^^^^^^ Comment only narrates what the method does; delete it or state a constraint.
      def self.payload; end
    RUBY
  end

  it "accepts a comment that states a constraint" do
    expect_no_offenses(<<~RUBY)
      # Callers must hold the row lock.
      def current_user; end
    RUBY
  end

  it "ignores narration that is part of a larger block" do
    expect_no_offenses(<<~RUBY)
      # Returns the user.
      # A second line makes this a block, not lone narration.
      def current_user; end
    RUBY
  end

  it "ignores a narration comment not attached to a method" do
    expect_no_offenses(<<~RUBY)
      # Returns early on nil
      x = 1
    RUBY
  end
end
