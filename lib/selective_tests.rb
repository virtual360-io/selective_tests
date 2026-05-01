# frozen_string_literal: true

require 'selective_tests/version'
require 'selective_tests/configuration'

module SelectiveTests
  TRACKING_ENV = 'TRACK_TEST_FILES'

  class << self
    def config
      @config ||= Configuration.new
    end

    def configure
      yield config
    end

    def tracking_enabled?
      ENV[TRACKING_ENV].to_s.downcase == 'true'
    end

    def reset_config!
      @config = nil
    end
  end
end
