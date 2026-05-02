# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'pathname'

module SelectiveTests
  class Manifest
    FILE_GLOB         = 'run-*.ndjson'
    CONSOLIDATED_FILE = 'manifest.json'

    attr_reader :dir, :project_root

    def initialize(dir, project_root: Dir.pwd)
      @dir = dir
      @project_root = Pathname.new(File.expand_path(project_root))
    end

    def writer
      Writer.new(dir, project_root)
    end

    def reverse_index
      consolidated_path = File.join(@dir, CONSOLIDATED_FILE)
      return build_reverse_from_ndjson unless File.exist?(consolidated_path)

      parsed = JSON.parse(File.read(consolidated_path))
      return {} unless parsed.is_a?(Hash)

      parsed.transform_values { |tests| Array(tests).uniq.sort }
    rescue JSON::ParserError
      build_reverse_from_ndjson
    end

    def entries
      result = {}
      reverse_index.each do |file, tests|
        Array(tests).each { |test| (result[test] ||= []) << file }
      end
      result.transform_values { |files| files.uniq.sort }
    end

    def consolidate(prune: false)
      sorted = build_reverse_from_ndjson.sort.to_h
      FileUtils.mkdir_p(@dir)
      path = File.join(@dir, CONSOLIDATED_FILE)
      File.write(path, JSON.generate(sorted) + "\n")
      run_files.each { |f| File.delete(f) } if prune
      path
    end

    def consolidated?
      File.exist?(File.join(@dir, CONSOLIDATED_FILE))
    end

    def clear!
      run_files.each { |f| File.delete(f) }
      consolidated_path = File.join(@dir, CONSOLIDATED_FILE)
      File.delete(consolidated_path) if File.exist?(consolidated_path)
    end

    def run_files
      Dir.glob(File.join(@dir, FILE_GLOB))
    end

    private

    def build_reverse_from_ndjson
      forward = {}
      run_files.each do |path|
        File.foreach(path) do |line|
          line.strip!
          next if line.empty?

          row = JSON.parse(line)
          forward[row['test']] = row['files']
        rescue JSON::ParserError
          next
        end
      end

      index = Hash.new { |h, k| h[k] = [] }
      forward.each do |test, files|
        Array(files).each { |f| index[f] << test }
      end
      index.transform_values { |tests| tests.uniq.sort }
    end

    class Writer
      def initialize(dir, project_root)
        @dir = dir
        @project_root = project_root
        @path = nil
        @file = nil
      end

      def write(test_path, files)
        rel_test = relativize(test_path)
        return unless rel_test

        rel_files = files.filter_map { |f| relativize(f) }.uniq.sort
        line = JSON.generate(test: rel_test, files: rel_files, recorded_at: Time.now.to_i)
        file.puts(line)
      end

      def close
        @file&.close
        @file = nil
      end

      private

      def file
        @file ||= begin
          FileUtils.mkdir_p(@dir)
          @path = File.join(@dir, "run-#{Process.pid}.ndjson")
          File.open(@path, 'a').tap { |f| f.sync = true }
        end
      end

      def relativize(path)
        return nil unless path

        absolute = File.expand_path(path)
        root = @project_root.to_s
        return nil unless absolute.start_with?(root + File::SEPARATOR) || absolute == root

        absolute[(root.length + 1)..]
      end
    end
  end
end
