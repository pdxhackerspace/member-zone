require 'test_helper'

class QueuedMailRetrySweepJobTest < ActiveSupport::TestCase
  setup do
    ActionMailer::Base.deliveries.clear
    @queued_mail = queued_mails(:pending_mail)
    @queued_mail.update!(status: 'approved', last_error: 'SocketError: getaddrinfo(3)',
                         last_error_at: 1.hour.ago, send_attempts: 1)
  end

  test 'sends a message whose backoff has elapsed' do
    assert_difference 'ActionMailer::Base.deliveries.size', 1 do
      QueuedMailRetrySweepJob.perform_now
    end

    @queued_mail.reload
    assert_not_nil @queued_mail.sent_at
    assert_nil @queued_mail.last_error
    assert_equal 2, @queued_mail.send_attempts
  end

  test 'leaves a message alone until its backoff has elapsed' do
    @queued_mail.update!(last_error_at: 5.seconds.ago)

    assert_no_difference 'ActionMailer::Base.deliveries.size' do
      QueuedMailRetrySweepJob.perform_now
    end

    assert_nil @queued_mail.reload.sent_at
  end

  test 'gives up once the attempt budget is spent' do
    @queued_mail.update!(send_attempts: QueuedMailRetries::MAX_SEND_ATTEMPTS)

    assert_no_difference 'ActionMailer::Base.deliveries.size' do
      QueuedMailRetrySweepJob.perform_now
    end

    assert_nil @queued_mail.reload.sent_at
    assert @queued_mail.retries_exhausted?
    assert_nil @queued_mail.next_retry_at
  end

  test 'does nothing while email is disabled' do
    with_email_disabled do
      assert_no_difference 'ActionMailer::Base.deliveries.size' do
        QueuedMailRetrySweepJob.perform_now
      end
    end

    @queued_mail.reload
    assert_nil @queued_mail.sent_at
    assert_equal 1, @queued_mail.send_attempts, 'a disabled mail server must not cost an attempt'
  end

  test 'takes over a message whose delivery job never ran' do
    @queued_mail.update!(last_error: nil, last_error_at: nil, send_attempts: 0)
    @queued_mail.update_columns(updated_at: 1.hour.ago)

    assert_difference 'ActionMailer::Base.deliveries.size', 1 do
      QueuedMailRetrySweepJob.perform_now
    end

    assert_not_nil @queued_mail.reload.sent_at
  end

  test 'leaves a freshly approved message to its own delivery job' do
    @queued_mail.update!(last_error: nil, last_error_at: nil, send_attempts: 0)

    assert_no_difference 'ActionMailer::Base.deliveries.size' do
      QueuedMailRetrySweepJob.perform_now
    end

    assert_nil @queued_mail.reload.sent_at
  end

  test 'sweeps every due message in one run' do
    other = QueuedMail.create!(
      to: 'someone-else@example.com',
      subject: 'Test Org: Application Received',
      body_html: '<p>Hello</p>',
      body_text: 'Hello',
      reason: 'Application received',
      mailer_action: 'application_received',
      recipient: users(:two),
      status: 'approved',
      last_error: 'SocketError: getaddrinfo(3)',
      last_error_at: 1.hour.ago,
      send_attempts: 1
    )

    assert_difference 'ActionMailer::Base.deliveries.size', 2 do
      QueuedMailRetrySweepJob.perform_now
    end

    assert_not_nil @queued_mail.reload.sent_at
    assert_not_nil other.reload.sent_at
  end
end
