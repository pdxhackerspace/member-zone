require 'test_helper'

class QueuedMailImmediateSendTest < ActiveSupport::TestCase
  setup do
    ActionMailer::Base.deliveries.clear
    EmailTemplate.where(key: 'training_completed').delete_all
    EmailTemplate.create!(
      key: 'training_completed',
      name: 'Training Completed Immediate',
      subject: 'You were trained on {{training_topic}}',
      body_html: '<p>Nice work, {{member_name}}</p>',
      body_text: 'Nice work, {{member_name}}',
      enabled: true,
      send_immediately: true
    )
    @member = users(:one)
  end

  test 'an unreachable mail server queues the message instead of raising' do
    record = nil

    with_unreachable_mail_server do
      assert_difference 'QueuedMail.count', 1 do
        record = QueuedMail.enqueue(:training_completed, @member,
                                    reason: 'Trained in Laser Cutter', training_topic: 'Laser Cutter')
      end
    end

    assert_instance_of QueuedMail, record
    assert record.approved?, 'a message cleared to send immediately must not go back for review'
    assert_nil record.sent_at
    assert record.delivery_failed?
    assert_match(/Name or service not known/, record.last_error)
    assert_equal 0, record.send_attempts, 'the failed immediate send should not spend a retry attempt'
  end

  test 'a queued immediate send keeps the reason and arguments it was raised with' do
    record = nil

    with_unreachable_mail_server do
      record = QueuedMail.enqueue(:training_completed, @member,
                                  reason: 'Trained in Laser Cutter', training_topic: 'Laser Cutter')
    end

    assert_equal 'Trained in Laser Cutter', record.reason
    assert_equal 'training_completed', record.mailer_action
    assert_equal 'Laser Cutter', record.mailer_args['training_topic']
    assert_equal @member, record.recipient
    assert_equal 'You were trained on Laser Cutter', record.subject
    assert record.can_regenerate?
  end

  test 'a failed immediate send is logged against the queued message' do
    record = nil

    with_unreachable_mail_server do
      record = QueuedMail.enqueue(:training_completed, @member, training_topic: 'Laser Cutter')
    end

    entry = record.mail_log_entries.find_by(event: 'created')
    assert_not_nil entry
    assert_match(/for retry/, entry.details)
  end

  test 'the queued message is due for a retry once the first backoff has passed' do
    record = nil

    with_unreachable_mail_server do
      record = QueuedMail.enqueue(:training_completed, @member, training_topic: 'Laser Cutter')
    end

    assert_not record.retry_due?, 'the first retry waits out the backoff'
    assert record.retry_due?(now: 2.minutes.from_now)
    assert_equal record.last_error_at + 1.minute, record.next_retry_at
  end

  test 'disabled email queues the message without attempting delivery' do
    record = nil

    with_email_disabled do
      assert_no_difference 'ActionMailer::Base.deliveries.size' do
        record = QueuedMail.enqueue(:training_completed, @member, training_topic: 'Laser Cutter')
      end
    end

    assert_instance_of QueuedMail, record
    assert record.approved?
    assert_match(/Not attempted/, record.last_error)
    assert_match(/placeholder host/, record.last_error)
  end

  test 'a reachable mail server still sends immediately' do
    result = nil

    assert_no_difference 'QueuedMail.count' do
      assert_difference 'ActionMailer::Base.deliveries.size', 1 do
        result = QueuedMail.enqueue(:training_completed, @member, training_topic: 'Laser Cutter')
      end
    end

    assert_instance_of QueuedMail::ImmediateDelivery, result
  end
end
