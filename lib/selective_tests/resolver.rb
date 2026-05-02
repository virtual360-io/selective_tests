# frozen_string_literal: true

module SelectiveTests
  class Resolver
    Result = Struct.new(:mode, :reason, :tests, :unknown, keyword_init: true) do
      def selective?
        mode == 'selective'
      end

      def full?
        mode == 'full'
      end

      def skip?
        mode == 'skip'
      end
    end

    MODES = %w[skip selective full].freeze

    def initialize(manifest:, broad_patterns: [], ignore_patterns: [],
                   test_pattern: Configuration::DEFAULT_TEST_PATTERN)
      @manifest = manifest
      @broad_patterns = Array(broad_patterns)
      @ignore_patterns = Array(ignore_patterns)
      @test_pattern = test_pattern
    end

    def resolve(changed_files)
      changed = Array(changed_files).map { |f| f.to_s.strip }.reject(&:empty?)

      return result('skip', 'no-changes', []) if changed.empty?

      broad = changed.find { |f| match_any?(f, @broad_patterns) }
      return result('full', 'broad-change', [], detail: broad) if broad

      relevant = changed.reject { |f| match_any?(f, @ignore_patterns) }
      return result('skip', 'docs-only', []) if relevant.empty?

      return result('full', 'no-manifest', []) unless manifest_available?

      selection = Selector.new(@manifest, test_pattern: @test_pattern).select(relevant)

      return result('full', 'unknown-files', [], unknown: selection.unknown) if selection.unknown.any?
      return result('skip', 'no-tests-affected', []) if selection.tests.empty?

      result('selective', 'mapped', selection.tests)
    end

    private

    def match_any?(file, patterns)
      patterns.any? { |p| p.is_a?(Regexp) ? file.match?(p) : file == p.to_s }
    end

    def manifest_available?
      return false if @manifest.nil?

      @manifest.entries.any?
    rescue Errno::ENOENT
      false
    end

    def result(mode, reason, tests, unknown: [], detail: nil)
      Result.new(mode: mode, reason: detail ? "#{reason}:#{detail}" : reason, tests: tests, unknown: unknown)
    end
  end
end
