# frozen_string_literal: true

require 'test_helper'
require 'stringio'
require 'selective_tests/cli'

class CLITest < Minitest::Test
  def setup
    @root = Dir.mktmpdir
    @dir  = File.join(@root, '.selective_tests')
    FileUtils.mkdir_p(@dir)

    File.open(File.join(@dir, 'run-1.ndjson'), 'w') do |f|
      f.puts JSON.generate(test: 'test/foo_test.rb', files: ['app/foo.rb', 'lib/shared.rb'])
      f.puts JSON.generate(test: 'test/bar_test.rb', files: ['app/bar.rb'])
    end
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def run_cli(argv, stdin: '')
    stdout = StringIO.new
    stderr = StringIO.new
    stdin_io = StringIO.new(stdin)
    def stdin_io.tty?; false; end
    code = SelectiveTests::CLI.run(argv, stdout: stdout, stderr: stderr, stdin: stdin_io)
    [code, stdout.string, stderr.string]
  end

  def test_select_outputs_affected_tests
    code, out, err = run_cli(['select', '--root', @root, 'app/foo.rb'])

    assert_equal 0, code
    assert_equal "test/foo_test.rb\n", out
    assert_empty err
  end

  def test_select_includes_test_files_from_input
    code, out, _ = run_cli(['select', '--root', @root, 'test/baz_test.rb', 'app/foo.rb'])

    assert_equal 0, code
    lines = out.split("\n").sort
    assert_equal %w[test/baz_test.rb test/foo_test.rb], lines
  end

  def test_select_reports_unknown_files_to_stderr
    code, out, err = run_cli(['select', '--root', @root, 'app/who.rb'])

    assert_equal 0, code
    assert_empty out
    assert_match(/1 file\(s\) not in manifest/, err)
    assert_match(%r{app/who\.rb}, err)
  end

  def test_select_strict_returns_non_zero_when_unknown
    code, _, _ = run_cli(['select', '--root', @root, '--strict', 'app/who.rb'])

    assert_equal SelectiveTests::CLI::EXIT_STRICT_UNKNOWN, code
  end

  def test_select_reads_files_from_stdin_when_no_args
    code, out, _ = run_cli(['select', '--root', @root], stdin: "app/foo.rb\napp/bar.rb\n")

    assert_equal 0, code
    assert_equal %w[test/bar_test.rb test/foo_test.rb], out.split("\n").sort
  end

  def test_select_null_separator
    _, out, _ = run_cli(['select', '--root', @root, '--null', 'app/foo.rb', 'app/bar.rb'])

    assert_equal "test/bar_test.rb\0test/foo_test.rb\0", out
  end

  def test_info_prints_stats
    code, out, _ = run_cli(['info', '--root', @root])

    assert_equal 0, code
    assert_match(/tests_recorded:\s+2/, out)
    assert_match(/files_tracked:\s+3/, out)
  end

  def test_clear_removes_run_files
    code, out, _ = run_cli(['clear', '--root', @root])

    assert_equal 0, code
    assert_match(/removed 1 run file/, out)
    assert_empty Dir.glob(File.join(@dir, 'run-*.ndjson'))
  end

  def test_help_command
    code, out, _ = run_cli(['help'])

    assert_equal 0, code
    assert_match(/Usage: selective-tests/, out)
  end

  def test_unknown_command_returns_error
    code, _, err = run_cli(['frobnicate'])

    assert_equal SelectiveTests::CLI::EXIT_USAGE, code
    assert_match(/unknown command/, err)
  end
end
