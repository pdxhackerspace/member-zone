module Reminders
  # Sends parking permit/ticket reminder emails and expires notices that are past due.
  # Disabled by default via ReminderSetting; the initial issued email on creation is separate.
  class NotifyParkingNotices
    def self.call(now: Time.current)
      new(now: now).call
    end

    def initialize(now:)
      @now = now
    end

    def call
      expire_past_due_notices!
      return unless reminders_enabled?

      ParkingNoticeEligibility.due(now: @now).find_each { |notice| notify_notice(notice) }
    end

    private

    def reminders_enabled?
      ParkingNoticeEligibility.reminder_enabled?
    end

    def expire_past_due_notices!
      ParkingNotice.needing_expiration.includes(:members).find_each do |notice|
        notice.expire!
        notice.record_journal_entry!('parking_notice_expired') if notice.members.any?
      end
    end

    def notify_notice(notice)
      notice.with_lock do
        phase = ParkingNoticeEligibility.phase_for(notice, now: @now)
        return if phase.nil?

        deliver_reminder!(notice, phase)
      end
    end

    def deliver_reminder!(notice, phase)
      template_key = notice.template_key_for_reminder_phase(phase)
      return if template_key.blank?

      results = notice.deliverable_members.filter_map do |member|
        notice.enqueue_notification!(template_key, recipient: member)
      end
      return if results.empty?

      # Mail held for review has not reached the member yet, so the clock on the next reminder
      # only starts once something actually went out.
      return unless results.any?(QueuedMail::ImmediateDelivery)

      ParkingNoticeEligibility.record_delivery!(notice, at: @now)
    rescue StandardError => e
      Rails.logger.error(
        "[NotifyParkingNotices] notice_id=#{notice.id} phase=#{phase} failed: #{e.class}: #{e.message}"
      )
    end
  end
end
