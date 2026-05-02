# frozen_string_literal: true

require 'set'

module SelectiveTests
  # Captures template paths rendered during a test by subscribing to
  # ActiveSupport::Notifications events that ActionView (and ActionMailer) emit
  # for each render. Coverage stdlib only sees `.rb` files, so without this we
  # would never map `.html.erb` (or `.text.erb`, `.json.jbuilder`, etc.) to the
  # tests that exercise them.
  #
  # Activated automatically when ActiveSupport::Notifications is loaded.
  module ViewTracker
    EVENTS = %w[
      render_template.action_view
      render_partial.action_view
      render_layout.action_view
      render_collection.action_view
      render_template.action_mailer
    ].freeze

    @mutex = Mutex.new
    @paths = Set.new
    @subscribers = []
    @started = false

    class << self
      def available?
        defined?(ActiveSupport::Notifications) ? true : false
      end

      def start
        return false unless available?
        return true if @started

        @subscribers = EVENTS.map do |event|
          ActiveSupport::Notifications.subscribe(event) do |*args|
            payload = args.last
            record(payload[:identifier]) if payload.is_a?(Hash)
          end
        end
        @started = true
      end

      def stop
        return unless @started

        @subscribers.each { |s| ActiveSupport::Notifications.unsubscribe(s) }
        @subscribers = []
        @started = false
      end

      def started?
        @started
      end

      def consume!
        @mutex.synchronize do
          result = @paths.to_a
          @paths.clear
          result
        end
      end

      def record(path)
        return unless path.is_a?(String) && !path.empty?

        @mutex.synchronize { @paths << path }
      end
    end
  end
end
