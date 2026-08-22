require 'test_helper'

class QueuedMailTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @pending = queued_mails(:pending_mail)
    @approved = queued_mails(:approved_mail)
    @rejected = queued_mails(:rejected_mail)
  end

  # ─── Validations ──────────────────────────────────────────────────

  test 'valid pending mail fixture' do
    assert @pending.valid?
  end

  test 'requires to' do
    @pending.to = nil
    assert_not @pending.valid?
    assert @pending.errors[:to].any?
  end

  test 'requires subject' do
    @pending.subject = nil
    assert_not @pending.valid?
    assert @pending.errors[:subject].any?
  end

  test 'requires body_html' do
    @pending.body_html = nil
    assert_not @pending.valid?
    assert @pending.errors[:body_html].any?
  end

  test 'requires reason' do
    @pending.reason = nil
    assert_not @pending.valid?
    assert @pending.errors[:reason].any?
  end

  test 'requires mailer_action' do
    @pending.mailer_action = nil
    assert_not @pending.valid?
    assert @pending.errors[:mailer_action].any?
  end

  test 'validates status inclusion' do
    @pending.status = 'invalid'
    assert_not @pending.valid?
    assert @pending.errors[:status].any?
  end

  # ─── Scopes ───────────────────────────────────────────────────────

  test 'pending scope returns only pending mails' do
    results = QueuedMail.pending
    assert results.all?(&:pending?)
    assert_includes results, @pending
    assert_not_includes results, @approved
    assert_not_includes results, @rejected
  end

  test 'approved scope returns only approved mails' do
    results = QueuedMail.approved
    assert results.all?(&:approved?)
    assert_includes results, @approved
  end

  test 'rejected scope returns only rejected mails' do
    results = QueuedMail.rejected
    assert results.all?(&:rejected?)
    assert_includes results, @rejected
  end

  test 'newest_first orders by created_at desc' do
    results = QueuedMail.newest_first.to_a
    assert_equal results, results.sort_by(&:created_at).reverse
  end

  # ─── Status predicates ────────────────────────────────────────────

  test 'pending? returns true for pending status' do
    assert @pending.pending?
    assert_not @approved.pending?
  end

  test 'approved? returns true for approved status' do
    assert @approved.approved?
    assert_not @pending.approved?
  end

  test 'rejected? returns true for rejected status' do
    assert @rejected.rejected?
    assert_not @pending.rejected?
  end

  # ─── Approve ──────────────────────────────────────────────────────

  test 'approve! sets status and sends mail' do
    reviewer = users(:one)

    assert_enqueued_jobs 1, only: QueuedMailDeliveryJob do
      assert @pending.approve!(reviewer)
    end

    assert @pending.approved?
    assert_equal reviewer, @pending.reviewed_by
    assert_not_nil @pending.reviewed_at
    # sent_at is set when the delivery job runs, not when enqueued
    assert_nil @pending.sent_at
  end

  test 'approve! rejects mail to a banned recipient' do
    @pending.recipient.update_columns(membership_state: 'banned_member')

    assert_no_enqueued_jobs only: QueuedMailDeliveryJob do
      assert_not @pending.approve!(users(:one))
    end

    assert @pending.rejected?
  end

  test 'enqueue sends immediate template without creating queued mail' do
    ActionMailer::Base.deliveries.clear
    EmailTemplate.where(key: 'application_received').delete_all
    EmailTemplate.create!(
      key: 'application_received',
      name: 'Application Received Immediate',
      subject: 'Immediate hello {{member_name}}',
      body_html: '<p>Hello {{member_name}}</p>',
      body_text: 'Hello {{member_name}}',
      enabled: true,
      send_immediately: true
    )

    result = nil
    assert_no_enqueued_jobs only: QueuedMailDeliveryJob do
      assert_no_difference 'QueuedMail.count' do
        assert_difference 'MailLogEntry.count', 1 do
          assert_difference 'ActionMailer::Base.deliveries.size', 1 do
            result = QueuedMail.enqueue(:application_received, users(:one), reason: 'Application received')
          end
        end
      end
    end

    assert_instance_of QueuedMail::ImmediateDelivery, result
    assert_equal users(:one).email, result.to
    entry = MailLogEntry.order(:created_at).last
    assert_nil entry.queued_mail_id
    assert_equal result.to, entry.delivery_to
    assert_equal result.subject, entry.delivery_subject
    assert_includes entry.message_body_html, "Hello #{users(:one).display_name}"
    assert_includes entry.message_body_text, "Hello #{users(:one).display_name}"
  end

  test 'record_delivery_failure logs failed queued message body snapshot' do
    @pending.update!(status: 'approved')

    @pending.record_delivery_failure!(RuntimeError.new('smtp down'))

    entry = @pending.mail_log_entries.where(event: 'send_failed').last
    assert_equal @pending.to, entry.delivery_to
    assert_equal @pending.subject, entry.delivery_subject
    assert_equal @pending.body_html, entry.message_body_html
    assert_equal @pending.body_text, entry.message_body_text
  end

  test 'record_delivery_failure registers monitor failure and does not mark sent' do
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache.lookup_store(:memory_store)
    Rails.cache.clear
    @pending.update!(status: 'approved')

    assert_no_changes -> { @pending.reload.sent_at } do
      @pending.record_delivery_failure!(RuntimeError.new('smtp down'))
    end

    assert_equal 1, MailerDeliveryMonitor.recent_failures.size
    assert_match(/smtp down/, MailerDeliveryMonitor.recent_failures.last['message'])
  ensure
    Rails.cache = original_cache if defined?(original_cache)
  end

  # ─── Reject ──────────────────────────────────────────────────────

  test 'reject! sets status without sending mail' do
    reviewer = users(:one)

    assert_no_enqueued_jobs only: QueuedMailDeliveryJob do
      @pending.reject!(reviewer)
    end

    assert @pending.rejected?
    assert_equal reviewer, @pending.reviewed_by
    assert_not_nil @pending.reviewed_at
    assert_nil @pending.sent_at
  end

  # ─── can_regenerate? ──────────────────────────────────────────────

  test 'can_regenerate? is true when recipient exists' do
    assert @pending.can_regenerate?
  end

  test 'can_regenerate? is false without recipient' do
    @pending.recipient = nil
    @pending.email_template = nil
    @pending.mailer_action = nil
    assert_not @pending.can_regenerate?
  end
end
