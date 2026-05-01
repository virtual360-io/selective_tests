# frozen_string_literal: true

module SelectiveTests
  class Selector
    Result = Struct.new(:tests, :unknown, :test_inputs, keyword_init: true) do
      def empty?
        tests.empty?
      end
    end

    def initialize(manifest, test_pattern: Configuration::DEFAULT_TEST_PATTERN)
      @manifest = manifest
      @test_pattern = test_pattern
      @reverse = nil
    end

    def select(changed_files)
      tests = []
      unknown = []
      test_inputs = []

      changed_files.each do |raw|
        file = raw.to_s.strip
        next if file.empty?

        if test_file?(file)
          tests << file
          test_inputs << file
        elsif reverse_index.key?(file)
          tests.concat(reverse_index[file])
        else
          unknown << file
        end
      end

      Result.new(
        tests: tests.uniq.sort,
        unknown: unknown.uniq.sort,
        test_inputs: test_inputs.uniq.sort
      )
    end

    private

    def test_file?(path)
      path =~ @test_pattern
    end

    def reverse_index
      @reverse ||= begin
        index = Hash.new { |h, k| h[k] = [] }
        @manifest.entries.each do |test, files|
          Array(files).each { |f| index[f] << test }
        end
        index.each_value(&:uniq!)
        index
      end
    end
  end
end
