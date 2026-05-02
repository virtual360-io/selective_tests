# frozen_string_literal: true

require 'test_helper'
require 'selective_tests/manifest'

class ManifestTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir
    @dir  = File.join(@root, '.selective_tests')
    FileUtils.mkdir_p(File.join(@root, 'test'))
    FileUtils.mkdir_p(File.join(@root, 'app'))
    File.write(File.join(@root, 'test', 'foo_test.rb'), '')
    File.write(File.join(@root, 'app', 'foo.rb'), '')

    @manifest = SelectiveTests::Manifest.new(@dir, project_root: @root)
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def test_writer_records_relative_paths
    writer = @manifest.writer
    writer.write(File.join(@root, 'test/foo_test.rb'), [File.join(@root, 'app/foo.rb')])
    writer.close

    entries = @manifest.entries
    assert_equal({ 'test/foo_test.rb' => ['app/foo.rb'] }, entries)
  end

  def test_writer_drops_paths_outside_project_root
    writer = @manifest.writer
    writer.write(File.join(@root, 'test/foo_test.rb'), [File.join(@root, 'app/foo.rb'), '/usr/lib/ruby/foo.rb'])
    writer.close

    entries = @manifest.entries
    assert_equal ['app/foo.rb'], entries['test/foo_test.rb']
  end

  def test_writer_skips_test_path_outside_project_root
    writer = @manifest.writer
    writer.write('/tmp/somewhere_else_test.rb', [File.join(@root, 'app/foo.rb')])
    writer.close

    assert_empty @manifest.entries
  end

  def test_entries_reads_multiple_run_files
    FileUtils.mkdir_p(@dir)
    File.write(File.join(@dir, 'run-1.ndjson'),
               JSON.generate(test: 'test/a_test.rb', files: ['app/a.rb']) + "\n")
    File.write(File.join(@dir, 'run-2.ndjson'),
               JSON.generate(test: 'test/b_test.rb', files: ['app/b.rb']) + "\n")

    entries = @manifest.entries
    assert_equal ['app/a.rb'], entries['test/a_test.rb']
    assert_equal ['app/b.rb'], entries['test/b_test.rb']
  end

  def test_entries_keeps_latest_record_for_same_test
    FileUtils.mkdir_p(@dir)
    File.open(File.join(@dir, 'run-1.ndjson'), 'w') do |f|
      f.puts JSON.generate(test: 'test/a_test.rb', files: ['app/old.rb'])
      f.puts JSON.generate(test: 'test/a_test.rb', files: ['app/new.rb'])
    end

    assert_equal ['app/new.rb'], @manifest.entries['test/a_test.rb']
  end

  def test_clear_removes_run_files
    FileUtils.mkdir_p(@dir)
    File.write(File.join(@dir, 'run-1.ndjson'), '')
    File.write(File.join(@dir, 'run-2.ndjson'), '')
    File.write(File.join(@dir, 'keep.txt'), '')

    @manifest.clear!

    refute File.exist?(File.join(@dir, 'run-1.ndjson'))
    refute File.exist?(File.join(@dir, 'run-2.ndjson'))
    assert File.exist?(File.join(@dir, 'keep.txt'))
  end

  def test_skips_invalid_json_lines
    FileUtils.mkdir_p(@dir)
    File.open(File.join(@dir, 'run-1.ndjson'), 'w') do |f|
      f.puts 'not json'
      f.puts JSON.generate(test: 'test/a_test.rb', files: ['app/a.rb'])
    end

    assert_equal({ 'test/a_test.rb' => ['app/a.rb'] }, @manifest.entries)
  end

  def test_index_inverts_test_to_files_into_file_to_tests
    FileUtils.mkdir_p(@dir)
    File.open(File.join(@dir, 'run-1.ndjson'), 'w') do |f|
      f.puts JSON.generate(test: 'test/a_test.rb', files: ['app/shared.rb', 'app/a.rb'])
      f.puts JSON.generate(test: 'test/b_test.rb', files: ['app/shared.rb', 'app/b.rb'])
    end

    assert_equal(
      {
        'app/a.rb'      => ['test/a_test.rb'],
        'app/b.rb'      => ['test/b_test.rb'],
        'app/shared.rb' => ['test/a_test.rb', 'test/b_test.rb']
      },
      @manifest.reverse_index
    )
  end

  def test_consolidate_writes_manifest_json_with_inverted_index
    FileUtils.mkdir_p(@dir)
    File.open(File.join(@dir, 'run-1.ndjson'), 'w') do |f|
      f.puts JSON.generate(test: 'test/a_test.rb', files: ['app/shared.rb', 'app/a.rb'])
      f.puts JSON.generate(test: 'test/b_test.rb', files: ['app/shared.rb'])
    end

    path = @manifest.consolidate
    assert_equal File.join(@dir, 'manifest.json'), path
    assert @manifest.consolidated?

    written = JSON.parse(File.read(path))
    assert_equal(
      {
        'app/a.rb'      => ['test/a_test.rb'],
        'app/shared.rb' => ['test/a_test.rb', 'test/b_test.rb']
      },
      written
    )
  end

  def test_consolidate_with_prune_deletes_run_files
    FileUtils.mkdir_p(@dir)
    File.write(File.join(@dir, 'run-1.ndjson'),
               JSON.generate(test: 'test/a_test.rb', files: ['app/a.rb']) + "\n")
    File.write(File.join(@dir, 'run-2.ndjson'),
               JSON.generate(test: 'test/b_test.rb', files: ['app/b.rb']) + "\n")

    @manifest.consolidate(prune: true)

    assert_empty Dir.glob(File.join(@dir, 'run-*.ndjson'))
    assert File.exist?(File.join(@dir, 'manifest.json'))
  end

  def test_index_prefers_manifest_json_when_present
    FileUtils.mkdir_p(@dir)
    File.write(
      File.join(@dir, 'manifest.json'),
      JSON.generate('app/from_manifest.rb' => ['test/from_manifest_test.rb'])
    )
    File.write(File.join(@dir, 'run-1.ndjson'),
               JSON.generate(test: 'test/ignored_test.rb', files: ['app/ignored.rb']) + "\n")

    assert_equal(
      { 'app/from_manifest.rb' => ['test/from_manifest_test.rb'] },
      @manifest.reverse_index
    )
  end

  def test_index_falls_back_to_runs_when_manifest_json_is_invalid
    FileUtils.mkdir_p(@dir)
    File.write(File.join(@dir, 'manifest.json'), 'not json')
    File.write(File.join(@dir, 'run-1.ndjson'),
               JSON.generate(test: 'test/a_test.rb', files: ['app/a.rb']) + "\n")

    assert_equal({ 'app/a.rb' => ['test/a_test.rb'] }, @manifest.reverse_index)
  end

  def test_clear_also_removes_manifest_json
    FileUtils.mkdir_p(@dir)
    File.write(File.join(@dir, 'run-1.ndjson'), '')
    File.write(File.join(@dir, 'manifest.json'), '{}')

    @manifest.clear!

    refute File.exist?(File.join(@dir, 'run-1.ndjson'))
    refute File.exist?(File.join(@dir, 'manifest.json'))
  end

  def test_consolidated_predicate
    refute @manifest.consolidated?
    FileUtils.mkdir_p(@dir)
    File.write(File.join(@dir, 'manifest.json'), '{}')
    assert @manifest.consolidated?
  end
end
