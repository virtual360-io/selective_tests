# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

if ENV['TRACK_TEST_FILES'] == 'true'
  require 'coverage'
  Coverage.start unless Coverage.running?
end

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'

require 'selective_tests/minitest' if ENV['TRACK_TEST_FILES'] == 'true'
