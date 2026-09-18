require 'test_helper'

class TestMailerTest < ActionMailer::TestCase
  class FailingDelivery
    def initialize(_settings = {}); end

    def deliver!(_mail)
      raise 'smtp down'
    end
  end

  setup do
    ActionMailer::Base.deliveries.clear
  end

  test 'sends the rendered template to the admin who asked for it' do
    assert_difference 'ActionMailer::Base.deliveries.size', 1 do
      test_send.deliver_now
    end

    assert_equal ['admin@example.com'], ActionMailer::Base.deliveries.last.to
  end

  # A template test send is a diagnostic an admin is watching for. Parking it in the mail queue
  # would have the retry sweep resending it for hours, long after they stopped looking and the
  # template they were testing has changed.
  test 'a failed test send is not parked in the mail queue for retry' do
    with_failing_delivery do
      assert_no_difference -> { QueuedMail.count } do
        assert_raises(RuntimeError) { test_send.deliver_now }
      end
    end
  end

  test 'a failed test send is still recorded in the mail log' do
    with_failing_delivery do
      assert_difference -> { MailLogEntry.where(event: 'send_failed', delivery_action: 'send_template').count }, 1 do
        assert_raises(RuntimeError) { test_send.deliver_now }
      end
    end

    entry = MailLogEntry.where(event: 'send_failed', delivery_action: 'send_template').last

    assert_equal 'admin@example.com', entry.delivery_to
    assert_match(/smtp down/, entry.details)
  end

  private

  def test_send
    TestMailer.send_template(
      to: 'admin@example.com',
      subject: 'Test Org: Template preview',
      body_html: '<p>Preview body.</p>',
      body_text: 'Preview body.'
    )
  end

  def with_failing_delivery
    ActionMailer::Base.add_delivery_method :test_mailer_failure, FailingDelivery
    original_delivery_method = ActionMailer::Base.delivery_method
    ActionMailer::Base.delivery_method = :test_mailer_failure
    yield
  ensure
    ActionMailer::Base.delivery_method = original_delivery_method if defined?(original_delivery_method)
  end
end
