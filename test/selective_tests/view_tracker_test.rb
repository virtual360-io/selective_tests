# frozen_string_literal: true

require 'test_helper'
require 'active_support/isolated_execution_state'
require 'active_support/notifications'
require 'selective_tests/view_tracker'

class ViewTrackerTest < Minitest::Test
  def setup
    SelectiveTests::ViewTracker.stop
    SelectiveTests::ViewTracker.consume!
  end

  def teardown
    SelectiveTests::ViewTracker.stop
    SelectiveTests::ViewTracker.consume!
  end

  def test_available_when_active_support_notifications_loaded
    assert SelectiveTests::ViewTracker.available?
  end

  def test_start_subscribes_to_known_events_and_records_identifier
    SelectiveTests::ViewTracker.start
    assert SelectiveTests::ViewTracker.started?

    ActiveSupport::Notifications.instrument('render_template.action_view',
                                            identifier: '/app/views/users/show.html.erb')
    ActiveSupport::Notifications.instrument('render_partial.action_view',
                                            identifier: '/app/views/users/_form.html.erb')
    ActiveSupport::Notifications.instrument('render_layout.action_view',
                                            identifier: '/app/views/layouts/app.html.erb')
    ActiveSupport::Notifications.instrument('render_collection.action_view',
                                            identifier: '/app/views/users/_row.html.erb')
    ActiveSupport::Notifications.instrument('render_template.action_mailer',
                                            identifier: '/app/views/mailers/notify.html.erb')

    captured = SelectiveTests::ViewTracker.consume!.sort
    assert_equal(
      [
        '/app/views/layouts/app.html.erb',
        '/app/views/mailers/notify.html.erb',
        '/app/views/users/_form.html.erb',
        '/app/views/users/_row.html.erb',
        '/app/views/users/show.html.erb'
      ],
      captured
    )
  end

  def test_consume_clears_recorded_paths
    SelectiveTests::ViewTracker.start
    ActiveSupport::Notifications.instrument('render_template.action_view',
                                            identifier: '/x.html.erb')

    assert_equal ['/x.html.erb'], SelectiveTests::ViewTracker.consume!
    assert_empty SelectiveTests::ViewTracker.consume!
  end

  def test_dedupes_within_a_window
    SelectiveTests::ViewTracker.start
    3.times do
      ActiveSupport::Notifications.instrument('render_partial.action_view',
                                              identifier: '/shared.html.erb')
    end

    assert_equal ['/shared.html.erb'], SelectiveTests::ViewTracker.consume!
  end

  def test_ignores_blank_or_non_string_identifiers
    SelectiveTests::ViewTracker.start
    ActiveSupport::Notifications.instrument('render_template.action_view', identifier: '')
    ActiveSupport::Notifications.instrument('render_template.action_view', identifier: nil)
    ActiveSupport::Notifications.instrument('render_template.action_view', identifier: 123)
    ActiveSupport::Notifications.instrument('render_template.action_view', other_key: 'x')

    assert_empty SelectiveTests::ViewTracker.consume!
  end

  def test_stop_unsubscribes
    SelectiveTests::ViewTracker.start
    SelectiveTests::ViewTracker.stop
    refute SelectiveTests::ViewTracker.started?

    ActiveSupport::Notifications.instrument('render_template.action_view',
                                            identifier: '/should_not_capture.html.erb')

    assert_empty SelectiveTests::ViewTracker.consume!
  end

  def test_start_is_idempotent
    assert SelectiveTests::ViewTracker.start
    assert SelectiveTests::ViewTracker.start
    assert SelectiveTests::ViewTracker.started?
  end
end
