# frozen_string_literal: true

require "spec_helper"

RSpec.describe RuboCop::Cop::Harness::AnnotationTicketRef, :config do
  it "flags a TODO with no ticket reference" do
    expect_offense(<<~'RUBY')
      # TODO: handle retries
      ^^^^^^^^^^^^^^^^^^^^^^ TODO must reference a tracker ticket (matching /[A-Z]{2,}-\d+/).
      run
    RUBY
  end

  it "flags a FIXME with no ticket reference" do
    expect_offense(<<~'RUBY')
      # FIXME the edge case
      ^^^^^^^^^^^^^^^^^^^^^ FIXME must reference a tracker ticket (matching /[A-Z]{2,}-\d+/).
      run
    RUBY
  end

  it "accepts a TODO that carries a ticket" do
    expect_no_offenses(<<~RUBY)
      # TODO(VEN-1234): handle retries
      run
    RUBY
  end

  it "does not treat a substring as an annotation keyword" do
    expect_no_offenses(<<~RUBY)
      # mastodon integration notes
      run
    RUBY
  end
end
