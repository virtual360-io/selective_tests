# frozen_string_literal: true

require 'test_helper'
require 'selective_tests/manifest'
require 'selective_tests/selector'

class SelectorTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir
    @dir  = File.join(@root, '.selective_tests')
    FileUtils.mkdir_p(@dir)

    File.open(File.join(@dir, 'run-1.ndjson'), 'w') do |f|
      f.puts JSON.generate(test: 'test/foo_test.rb', files: ['app/foo.rb', 'lib/shared.rb'])
      f.puts JSON.generate(test: 'test/bar_test.rb', files: ['app/bar.rb', 'lib/shared.rb'])
    end

    @manifest = SelectiveTests::Manifest.new(@dir, project_root: @root)
    @selector = SelectiveTests::Selector.new(@manifest)
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def test_changed_app_file_returns_only_dependent_test
    result = @selector.select(['app/foo.rb'])

    assert_equal ['test/foo_test.rb'], result.tests
    assert_empty result.unknown
  end

  def test_shared_file_returns_all_dependent_tests
    result = @selector.select(['lib/shared.rb'])

    assert_equal %w[test/bar_test.rb test/foo_test.rb], result.tests
  end

  def test_test_file_in_input_is_returned_directly
    result = @selector.select(['test/some_other_test.rb'])

    assert_equal ['test/some_other_test.rb'], result.tests
    assert_empty result.unknown
    assert_equal ['test/some_other_test.rb'], result.test_inputs
  end

  def test_unknown_non_test_file_is_reported
    result = @selector.select(['app/unmapped.rb'])

    assert_empty result.tests
    assert_equal ['app/unmapped.rb'], result.unknown
  end

  def test_combination_of_inputs
    result = @selector.select(['app/foo.rb', 'test/bar_test.rb', 'app/unmapped.rb'])

    assert_equal %w[test/bar_test.rb test/foo_test.rb], result.tests
    assert_equal ['app/unmapped.rb'], result.unknown
  end

  def test_empty_and_blank_inputs_are_ignored
    result = @selector.select(['', '   ', "\n"])

    assert_empty result.tests
    assert_empty result.unknown
  end

  def test_custom_test_pattern
    selector = SelectiveTests::Selector.new(@manifest, test_pattern: /\Aspec\//)
    result = selector.select(['spec/whatever_spec.rb', 'test/bar_test.rb'])

    assert_includes result.tests, 'spec/whatever_spec.rb'
    refute_includes result.tests, 'test/bar_test.rb'
    assert_includes result.unknown, 'test/bar_test.rb'
  end
end
