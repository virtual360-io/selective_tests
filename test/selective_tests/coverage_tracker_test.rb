# frozen_string_literal: true

require 'test_helper'
require 'selective_tests/coverage_tracker'

class CoverageTrackerTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @file_a = File.join(@tmpdir, 'a.rb')
    @file_b = File.join(@tmpdir, 'b.rb')

    File.write(@file_a, <<~RUBY)
      module SelectiveTestsFixtureA
        def self.run
          1 + 1
        end
      end
    RUBY

    File.write(@file_b, <<~RUBY)
      module SelectiveTestsFixtureB
        def self.run
          2 + 2
        end
      end
    RUBY
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_consume_returns_files_executed_since_last_call
    SelectiveTests::CoverageTracker.start
    require @file_a
    SelectiveTestsFixtureA.run

    files = SelectiveTests::CoverageTracker.consume!
    assert_includes files, @file_a

    require @file_b
    SelectiveTestsFixtureB.run

    files = SelectiveTests::CoverageTracker.consume!
    assert_includes files, @file_b
    refute_includes files, @file_a, 'consume! should clear counters between calls'
  end
end
