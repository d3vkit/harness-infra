# frozen_string_literal: true

require "spec_helper"

RSpec.describe RuboCop::Cop::Harness::BannerComment, :config do
  it "flags an equals-sign divider banner" do
    expect_offense(<<~RUBY)
      # ======
      ^^^^^^^^ Decorative divider banner carries no information; remove it.
      x = 1
    RUBY
  end

  it "flags a dash divider banner" do
    expect_offense(<<~RUBY)
      # ----------
      ^^^^^^^^^^^^ Decorative divider banner carries no information; remove it.
      x = 1
    RUBY
  end

  it "accepts an ordinary explanatory comment" do
    expect_no_offenses(<<~RUBY)
      # A normal note about the code.
      x = 1
    RUBY
  end

  it "accepts a short run below MinRepeat" do
    expect_no_offenses(<<~RUBY)
      # ---
      x = 1
    RUBY
  end

  it "accepts a titled divider (mixed content)" do
    expect_no_offenses(<<~RUBY)
      # == Section ==
      x = 1
    RUBY
  end
end
