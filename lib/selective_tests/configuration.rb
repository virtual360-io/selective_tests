# frozen_string_literal: true

module SelectiveTests
  class Configuration
    DEFAULT_MANIFEST_DIR = '.selective_tests'
    DEFAULT_TEST_PATTERN = /_test\.rb\z/

    attr_accessor :project_root, :manifest_dir, :test_pattern

    def initialize
      @project_root = detect_project_root
      @manifest_dir = ENV['SELECTIVE_TESTS_MANIFEST_DIR'] || File.join(@project_root, DEFAULT_MANIFEST_DIR)
      @test_pattern = DEFAULT_TEST_PATTERN
    end

    private

    def detect_project_root
      return ENV['SELECTIVE_TESTS_ROOT'] if ENV['SELECTIVE_TESTS_ROOT']
      return Rails.root.to_s if defined?(Rails) && Rails.respond_to?(:root) && Rails.root

      Dir.pwd
    end
  end
end
