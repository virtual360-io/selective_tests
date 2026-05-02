# frozen_string_literal: true

require 'json'
require 'optparse'
require 'selective_tests'
require 'selective_tests/manifest'
require 'selective_tests/selector'
require 'selective_tests/resolver'

module SelectiveTests
  class CLI
    EXIT_OK = 0
    EXIT_USAGE = 1
    EXIT_STRICT_UNKNOWN = 2

    COMMANDS = %w[select resolve consolidate info clear].freeze

    def self.run(argv, stdout: $stdout, stderr: $stderr, stdin: $stdin)
      new(stdout:, stderr:, stdin:).run(argv)
    end

    def initialize(stdout:, stderr:, stdin:)
      @stdout = stdout
      @stderr = stderr
      @stdin = stdin
    end

    def run(argv)
      argv = argv.dup
      command = argv.shift
      return print_help if command.nil? || %w[help --help -h].include?(command)
      return run_command(command, argv) if COMMANDS.include?(command)

      @stderr.puts("selective-tests: unknown command #{command.inspect}")
      print_help(io: @stderr)
      EXIT_USAGE
    end

    private

    def run_command(command, argv)
      send(command, argv)
    end

    def select(argv)
      options = base_options.merge(strict: false, null: false, test_pattern: nil)
      parser = OptionParser.new do |o|
        o.banner = 'Usage: selective-tests select [files...]'
        o.on('--manifest-dir DIR', String) { |v| options[:manifest_dir] = v }
        o.on('--root DIR', String)         { |v| options[:root] = v }
        o.on('--test-pattern REGEXP', String, 'Override default test pattern (Regexp source)') do |v|
          options[:test_pattern] = Regexp.new(v)
        end
        o.on('--strict', 'Exit non-zero if any input file is unknown to the manifest') do
          options[:strict] = true
        end
        o.on('-0', '--null', 'NUL-byte separated output (for `xargs -0`)') { options[:null] = true }
      end
      files = parser.parse(argv)
      files.concat(read_stdin) if files.empty? && !@stdin.tty?

      manifest = build_manifest(options)
      selector_kwargs = options[:test_pattern] ? { test_pattern: options[:test_pattern] } : {}
      result = Selector.new(manifest, **selector_kwargs).select(files)

      separator = options[:null] ? "\0" : "\n"
      result.tests.each { |t| @stdout.write(t, separator) }

      report_unknown(result.unknown) unless result.unknown.empty?
      return EXIT_STRICT_UNKNOWN if options[:strict] && !result.unknown.empty?

      EXIT_OK
    end

    def resolve(argv)
      options = base_options.merge(
        changed_files: nil,
        broad_patterns: [],
        ignore_patterns: [],
        format: 'lines',
        test_pattern: nil
      )
      parser = OptionParser.new do |o|
        o.banner = 'Usage: selective-tests resolve [files...]'
        o.on('--manifest-dir DIR', String) { |v| options[:manifest_dir] = v }
        o.on('--root DIR', String)         { |v| options[:root] = v }
        o.on('--changed-files FILE', String, 'Path to file with one changed file per line') do |v|
          options[:changed_files] = v
        end
        o.on('--broad-pattern REGEX', String, 'Repeatable; full mode if any changed file matches') do |v|
          options[:broad_patterns] << Regexp.new(v)
        end
        o.on('--broad-patterns FILE', String, 'File with one regex per line') do |v|
          options[:broad_patterns].concat(load_patterns(v))
        end
        o.on('--ignore-pattern REGEX', String, 'Repeatable; matched files are dropped before resolution') do |v|
          options[:ignore_patterns] << Regexp.new(v)
        end
        o.on('--ignore-patterns FILE', String, 'File with one regex per line') do |v|
          options[:ignore_patterns].concat(load_patterns(v))
        end
        o.on('--test-pattern REGEXP', String, 'Override default test pattern (Regexp source)') do |v|
          options[:test_pattern] = Regexp.new(v)
        end
        o.on('--format FORMAT', String, %w[lines github json], 'lines (default), github, json') do |v|
          options[:format] = v
        end
      end
      positional = parser.parse(argv)

      changed = read_changed_files(positional, options[:changed_files])

      manifest = build_manifest(options)
      resolver_kwargs = {
        manifest: manifest,
        broad_patterns: options[:broad_patterns],
        ignore_patterns: options[:ignore_patterns]
      }
      resolver_kwargs[:test_pattern] = options[:test_pattern] if options[:test_pattern]

      result = Resolver.new(**resolver_kwargs).resolve(changed)

      emit_result(result, options[:format])
      EXIT_OK
    end

    def consolidate(argv)
      options = base_options.merge(prune: false)
      OptionParser.new do |o|
        o.banner = 'Usage: selective-tests consolidate [--prune]'
        o.on('--manifest-dir DIR', String) { |v| options[:manifest_dir] = v }
        o.on('--root DIR', String)         { |v| options[:root] = v }
        o.on('--prune', 'Delete run-*.ndjson files after writing manifest.json') do
          options[:prune] = true
        end
      end.parse(argv)

      manifest = build_manifest(options)
      path = manifest.consolidate(prune: options[:prune])
      @stdout.puts "wrote #{path}"
      EXIT_OK
    end

    def info(argv)
      options = base_options
      OptionParser.new do |o|
        o.banner = 'Usage: selective-tests info'
        o.on('--manifest-dir DIR', String) { |v| options[:manifest_dir] = v }
        o.on('--root DIR', String)         { |v| options[:root] = v }
      end.parse(argv)

      manifest = build_manifest(options)
      entries = manifest.entries
      file_count = entries.values.flatten.uniq.size

      @stdout.puts "manifest_dir:    #{manifest.dir}"
      @stdout.puts "project_root:    #{manifest.project_root}"
      @stdout.puts "tests_recorded:  #{entries.size}"
      @stdout.puts "files_tracked:   #{file_count}"
      @stdout.puts "run_files:       #{manifest.run_files.size}"
      EXIT_OK
    end

    def clear(argv)
      options = base_options
      OptionParser.new do |o|
        o.banner = 'Usage: selective-tests clear'
        o.on('--manifest-dir DIR', String) { |v| options[:manifest_dir] = v }
        o.on('--root DIR', String)         { |v| options[:root] = v }
      end.parse(argv)

      manifest = build_manifest(options)
      removed = manifest.run_files.size
      manifest.clear!
      @stdout.puts "removed #{removed} run file(s) from #{manifest.dir}"
      EXIT_OK
    end

    def base_options
      { manifest_dir: nil, root: SelectiveTests.config.project_root }
    end

    def build_manifest(options)
      root = options[:root]
      manifest_dir = options[:manifest_dir] || File.join(root, Configuration::DEFAULT_MANIFEST_DIR)
      Manifest.new(manifest_dir, project_root: root)
    end

    def report_unknown(unknown)
      @stderr.puts "selective-tests: #{unknown.size} file(s) not in manifest:"
      unknown.first(10).each { |f| @stderr.puts "  - #{f}" }
      @stderr.puts "  ... (#{unknown.size - 10} more)" if unknown.size > 10
    end

    def read_stdin
      @stdin.read.split(/\s+/).reject(&:empty?)
    end

    def read_changed_files(positional, file_path)
      from_args = positional || []
      from_file = file_path ? File.readlines(file_path).map(&:strip).reject(&:empty?) : []
      from_stdin = positional.empty? && file_path.nil? && !@stdin.tty? ? read_stdin : []
      (from_args + from_file + from_stdin).uniq
    end

    def load_patterns(path)
      File.readlines(path).map(&:strip).reject { |l| l.empty? || l.start_with?('#') }.map { |l| Regexp.new(l) }
    end

    def emit_result(result, format)
      case format
      when 'lines'
        @stderr.puts "selective-tests: mode=#{result.mode} reason=#{result.reason}"
        result.tests.each { |t| @stdout.puts t }
      when 'github'
        @stdout.puts "mode=#{result.mode}"
        @stdout.puts "reason=#{result.reason}"
        @stdout.puts "test_count=#{result.tests.size}"
        @stdout.puts 'tests<<SELECTIVE_EOF'
        result.tests.each { |t| @stdout.puts t }
        @stdout.puts 'SELECTIVE_EOF'
      when 'json'
        @stdout.puts JSON.generate(
          mode: result.mode,
          reason: result.reason,
          test_count: result.tests.size,
          tests: result.tests,
          unknown: result.unknown
        )
      end
    end

    def print_help(io: @stdout)
      io.puts <<~HELP
        Usage: selective-tests <command> [options]

        Commands:
          select [files...]   Print tests affected by the given files (one per line).
                              Reads from stdin when no positional args are given.
          resolve [files...]  Decide run mode (full|selective|skip) for changed files.
                              Honors --broad-pattern (force full) and --ignore-pattern
                              (drop before resolving). Output via --format lines|github|json.
          consolidate         Merge run-*.ndjson into manifest.json (inverted index:
                              file -> [tests]). Pass --prune to delete the run files.
          info                Print manifest statistics.
          clear               Delete recorded manifest data.

        Tracking is enabled in the test runner by setting #{TRACKING_ENV}=true.
        See: vendor/selective_tests/README.md
      HELP
      EXIT_OK
    end
  end
end
