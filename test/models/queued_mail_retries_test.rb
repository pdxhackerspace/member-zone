require 'test_helper'

class QueuedMailRetriesTest < ActiveSupport::TestCase
  setup do
    ActionMailer::Base.deliveries.clear
    @queued_mail = queued_mails(:pending_mail)
    @queued_mail.update!(status: 'approved', last_error: 'SocketError: getaddrinfo(3)',
                         last_error_at: 1.hour.ago, send_attempts: 1)
  end

  test 'due_for_retry selects exactly the messages retry_due? accepts' do
    clear_the_queue
    now = Time.current
    candidates = [
      failed_mail(send_attempts: 1, last_error_at: now - 2.minutes),
      failed_mail(send_attempts: 1, last_error_at: now - 10.seconds),
      failed_mail(send_attempts: 3, last_error_at: now - 5.minutes),
      failed_mail(send_attempts: 3, last_error_at: now - 20.minutes),
      failed_mail(send_attempts: 6, last_error_at: now - 1.hour),
      failed_mail(send_attempts: 6, last_error_at: now - 7.hours),
      failed_mail(send_attempts: QueuedMailRetries::MAX_SEND_ATTEMPTS, last_error_at: now - 1.week)
    ]

    expected = candidates.select { |mail| mail.retry_due?(now: now) }.map(&:id).sort

    assert_equal 3, expected.size, 'one message per backoff step under test should be due'
    assert_equal expected, QueuedMail.due_for_retry(now: now).map(&:id).sort
  end

  test 'due_for_retry takes over a message whose delivery job never ran, after the grace period' do
    clear_the_queue
    fresh = failed_mail(send_attempts: 0, last_error_at: nil)
    stale = failed_mail(send_attempts: 0, last_error_at: nil)
    stale.update_columns(updated_at: 1.hour.ago)

    due = QueuedMail.due_for_retry.map(&:id)

    assert_includes due, stale.id
    assert_not_includes due, fresh.id
  end

  test 'a batch of due messages is not starved by older messages that are not' do
    clear_the_queue
    5.times do |i|
      exhausted = failed_mail(send_attempts: QueuedMailRetries::MAX_SEND_ATTEMPTS, last_error_at: 1.week.ago)
      exhausted.update_columns(created_at: (10 + i).days.ago)
    end
    due = failed_mail(send_attempts: 1, last_error_at: 1.hour.ago)

    assert_equal [due.id], QueuedMail.due_for_retry.limit(1).map(&:id)
  end

  test 'only one worker can claim a message for delivery' do
    first = QueuedMail.find(@queued_mail.id)
    second = QueuedMail.find(@queued_mail.id)

    assert first.claim_for_delivery!
    assert_not second.claim_for_delivery!, 'a second worker must not spend the same attempt'
    assert_equal 2, @queued_mail.reload.send_attempts
  end

  test 'a claim is refused once the message has been sent' do
    stale = QueuedMail.find(@queued_mail.id)
    @queued_mail.update!(sent_at: Time.current)

    assert_not stale.claim_for_delivery!
  end

  test 'deliver_now! leaves an already sent message alone' do
    @queued_mail.update!(sent_at: 1.day.ago)

    assert_no_difference 'ActionMailer::Base.deliveries.size' do
      @queued_mail.deliver_now!
    end
  end

  test 'deliver_now! sends once when two workers race the same message' do
    first = QueuedMail.find(@queued_mail.id)
    second = QueuedMail.find(@queued_mail.id)

    assert_difference 'ActionMailer::Base.deliveries.size', 1 do
      first.deliver_now!
      second.deliver_now!
    end

    assert_not_nil @queued_mail.reload.sent_at
  end

  private

  # Leaves only the messages a test creates for itself in the retry queue.
  def clear_the_queue
    QueuedMail.unsent.update_all(status: 'rejected')
  end

  def failed_mail(send_attempts:, last_error_at:)
    QueuedMail.create!(
      to: "retry-#{SecureRandom.hex(4)}@example.com",
      subject: 'Test Org: Application Received',
      body_html: '<p>Hello</p>',
      body_text: 'Hello',
      reason: 'Application received',
      mailer_action: 'application_received',
      recipient: users(:one),
      status: 'approved',
      send_attempts: send_attempts,
      last_error: last_error_at && 'SocketError: getaddrinfo(3)',
      last_error_at: last_error_at
    )
  end
end
