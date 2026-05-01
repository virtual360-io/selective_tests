# frozen_string_literal: true

require 'selective_tests'
require 'selective_tests/coverage_tracker'
require 'selective_tests/manifest'

module SelectiveTests
  module MinitestIntegration
    class << self
      attr_accessor :writer

      def install!
        return if @installed

        SelectiveTests::CoverageTracker.start

        manifest = SelectiveTests::Manifest.new(
          SelectiveTests.config.manifest_dir,
          project_root: SelectiveTests.config.project_root
        )
        @writer = manifest.writer

        ::Minitest::Test.prepend(TestHooks)
        ::Minitest.after_run { @writer&.close }

        @installed = true
      end
    end

    module TestHooks
      def before_setup
        SelectiveTests::CoverageTracker.consume!
        super
      end

      def after_teardown
        super
        files = SelectiveTests::CoverageTracker.consume!
        path = SelectiveTests::MinitestIntegration.send(:source_file_for, self)
        SelectiveTests::MinitestIntegration.writer&.write(path, files) if path
      end
    end

    class << self
      private

      def source_file_for(test_instance)
        test_instance.class.instance_method(test_instance.name).source_location&.first
      rescue NameError
        nil
      end
    end
  end
end

SelectiveTests::MinitestIntegration.install! if SelectiveTests.tracking_enabled?
