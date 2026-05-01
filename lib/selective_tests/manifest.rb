# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'pathname'

module SelectiveTests
  class Manifest
    FILE_GLOB = 'run-*.ndjson'

    attr_reader :dir, :project_root

    def initialize(dir, project_root: Dir.pwd)
      @dir = dir
      @project_root = Pathname.new(File.expand_path(project_root))
    end

    def writer
      Writer.new(dir, project_root)
    end

    def entries
      result = {}
      run_files.each do |path|
        File.foreach(path) do |line|
          line.strip!
          next if line.empty?

          row = JSON.parse(line)
          result[row['test']] = row['files']
        rescue JSON::ParserError
          next
        end
      end
      result
    end

    def clear!
      run_files.each { |f| File.delete(f) }
    end

    def run_files
      Dir.glob(File.join(dir, FILE_GLOB))
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
