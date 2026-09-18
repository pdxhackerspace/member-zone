require 'test_helper'

class QueuedMailDeliveryJobTest < ActiveJob::TestCase
  class FailingDelivery
    def initialize(_settings = {}); end

    def deliver!(_mail)
      raise 'smtp down'
    end
  end

  setup do
    ActionMailer::Base.deliveries.clear
    @queued_mail = queued_mails(:pending_mail)
    @queued_mail.update!(status: 'approved')
  end

  test 'delivers an approved message' do
    assert_difference 'ActionMailer::Base.deliveries.size', 1 do
      QueuedMailDeliveryJob.perform_now(@queued_mail.id)
    end

    assert_predicate @queued_mail.reload, :sent?
  end

  # The retry policy lives in one place. If this job retried as well it would resend on a schedule
  # that ignores the backoff, spends attempts the budget never accounted for, and keeps trying
  # while email is switched off.
  test 'a failed delivery is recorded and left for the retry sweep, not retried here' do
    ActionMailer::Base.add_delivery_method :member_zone_job_failure, FailingDelivery
    original_delivery_method = ActionMailer::Base.delivery_method
    ActionMailer::Base.delivery_method = :member_zone_job_failure

    assert_no_enqueued_jobs only: QueuedMailDeliveryJob do
      QueuedMailDeliveryJob.perform_now(@queued_mail.id)
    end

    @queued_mail.reload

    assert_predicate @queued_mail, :delivery_failed?
    assert_match(/smtp down/, @queued_mail.last_error)
    assert_equal 1, @queued_mail.send_attempts
  ensure
    ActionMailer::Base.delivery_method = original_delivery_method if defined?(original_delivery_method)
  end

  test 'a rejected message is not delivered even if a job for it is still in flight' do
    @queued_mail.update!(status: 'rejected')

    assert_no_difference 'ActionMailer::Base.deliveries.size' do
      QueuedMailDeliveryJob.perform_now(@queued_mail.id)
    end
  end

  test 'a deleted message is discarded rather than retried' do
    id = @queued_mail.id
    @queued_mail.destroy!

    assert_nothing_raised { QueuedMailDeliveryJob.perform_now(id) }
  end
end
