# frozen_string_literal: true

require 'test_helper'
require 'selective_tests/manifest'
require 'selective_tests/resolver'

class ResolverTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir
    @dir  = File.join(@root, '.selective_tests')
    FileUtils.mkdir_p(@dir)

    File.open(File.join(@dir, 'run-1.ndjson'), 'w') do |f|
      f.puts JSON.generate(test: 'test/foo_test.rb', files: ['app/foo.rb'])
      f.puts JSON.generate(test: 'test/bar_test.rb', files: ['app/bar.rb', 'lib/shared.rb'])
    end

    @manifest = SelectiveTests::Manifest.new(@dir, project_root: @root)
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def resolver(broad: [], ignore: [])
    SelectiveTests::Resolver.new(
      manifest: @manifest,
      broad_patterns: broad,
      ignore_patterns: ignore
    )
  end

  def test_no_changes_returns_skip
    result = resolver.resolve([])

    assert result.skip?
    assert_equal 'no-changes', result.reason
    assert_empty result.tests
  end

  def test_broad_pattern_match_forces_full
    result = resolver(broad: [%r{\Adb/schema\.rb\z}]).resolve(['db/schema.rb', 'app/foo.rb'])

    assert result.full?
    assert_match(/\Abroad-change:db\/schema\.rb\z/, result.reason)
  end

  def test_only_ignored_files_returns_skip
    result = resolver(ignore: [/\.md\z/i]).resolve(['README.md', 'docs/intro.md'])

    assert result.skip?
    assert_equal 'docs-only', result.reason
  end

  def test_test_file_input_is_always_returned
    result = resolver.resolve(['test/foo_test.rb'])

    assert result.selective?
    assert_equal ['test/foo_test.rb'], result.tests
  end

  def test_test_file_input_returned_even_when_not_in_manifest
    result = resolver.resolve(['test/brand_new_test.rb'])

    assert result.selective?
    assert_equal ['test/brand_new_test.rb'], result.tests
  end

  def test_mapped_app_file_returns_dependent_tests
    result = resolver.resolve(['lib/shared.rb'])

    assert result.selective?
    assert_equal ['test/bar_test.rb'], result.tests
    assert_equal 'mapped', result.reason
  end

  def test_unknown_non_test_file_falls_back_to_full
    result = resolver.resolve(['app/unmapped.rb'])

    assert result.full?
    assert_equal 'unknown-files', result.reason
    assert_equal ['app/unmapped.rb'], result.unknown
  end

  def test_unknown_file_with_test_file_still_falls_back_to_full
    result = resolver.resolve(['app/unmapped.rb', 'test/foo_test.rb'])

    assert result.full?
    assert_equal 'unknown-files', result.reason
  end

  def test_no_manifest_falls_back_to_full
    empty_dir = File.join(@root, 'empty')
    FileUtils.mkdir_p(empty_dir)
    empty_manifest = SelectiveTests::Manifest.new(empty_dir, project_root: @root)
    resolver = SelectiveTests::Resolver.new(
      manifest: empty_manifest,
      broad_patterns: [],
      ignore_patterns: []
    )

    result = resolver.resolve(['app/foo.rb'])

    assert result.full?
    assert_equal 'no-manifest', result.reason
  end

  def test_ignored_files_are_dropped_before_resolution
    result = resolver(ignore: [%r{\Adocs/}]).resolve(['docs/intro.md', 'app/foo.rb'])

    assert result.selective?
    assert_equal ['test/foo_test.rb'], result.tests
  end

  def test_changed_files_with_only_blanks_treated_as_no_changes
    result = resolver.resolve(['', "\n", '   '])

    assert result.skip?
    assert_equal 'no-changes', result.reason
  end

  def test_string_pattern_treated_as_literal_match
    result = resolver(broad: ['Gemfile.lock']).resolve(['Gemfile.lock', 'app/foo.rb'])

    assert result.full?
  end
end
