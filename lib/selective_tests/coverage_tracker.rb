# frozen_string_literal: true

require 'coverage'

module SelectiveTests
  module CoverageTracker
    module_function

    def start
      Coverage.start unless Coverage.running?
    end

    def consume!
      result = Coverage.result(stop: false, clear: true)
      result.each_with_object([]) do |(path, lines), acc|
        next unless lines

        acc << path if lines.any? { |l| l && l.positive? }
      end
    end
  end
end
