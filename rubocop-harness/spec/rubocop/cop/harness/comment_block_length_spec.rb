# frozen_string_literal: true

require "spec_helper"

RSpec.describe RuboCop::Cop::Harness::CommentBlockLength, :config do
  let(:cop_config) { { "Max" => 4 } }

  it "flags a comment block longer than Max" do
    expect_offense(<<~RUBY)
      # one
      ^^^^^ Comment block is 5 lines (max 4); move extended rationale to a design doc and leave a one-line pointer.
      # two
      # three
      # four
      # five
      x = 1
    RUBY
  end

  it "accepts a block exactly at the limit" do
    expect_no_offenses(<<~RUBY)
      # one
      # two
      # three
      # four
      x = 1
    RUBY
  end

  it "treats blank-line-separated groups as distinct blocks" do
    expect_no_offenses(<<~RUBY)
      # one
      # two

      # three
      # four
      x = 1
    RUBY
  end

  it "does not count a rubocop directive toward a block" do
    expect_no_offenses(<<~RUBY)
      # one
      # two
      # three
      # rubocop:disable Layout/LineLength
      # four
      x = 1
    RUBY
  end
end
