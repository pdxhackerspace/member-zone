module Reminders
  # Sends parking permit/ticket reminder emails and expires notices that are past due.
  # Disabled by default via ReminderSetting; the initial issued email on creation is separate.
  class NotifyParkingNotices
    def self.call(now: Time.current)
      new(now: now).call
    end

    def self.record_delivery!(notice, phase, at: Time.current)
      column = delivery_column_for(phase)
      return unless column

      notice.with_lock do
        notice.update_column(column, at)
      end
    end

    def self.delivery_column_for(phase)
      {
        pre_expiration: :pre_expiration_reminder_sent_at,
        expiration: :expiration_notice_sent_at,
        overdue: :overdue_reminder_sent_at,
        final: :final_reminder_sent_at
      }[phase]
    end

    def initialize(now:)
      @now = now
    end

    def call
      expire_without_reminders unless reminders_enabled?
      return unless reminders_enabled?

      ParkingNoticeEligibility.due(now: @now).find_each { |notice| notify_notice(notice) }
    end

    private

    def reminders_enabled?
      ReminderSetting.enabled?('parking_notices')
    end

    def expire_without_reminders
      ParkingNotice.needing_expiration.find_each do |notice|
        notice.expire!
        notice.record_journal_entry!('parking_notice_expired') if notice.user.present?
      end
    end

    def notify_notice(notice)
      notice.with_lock do
        phase = ParkingNoticeEligibility.due_phase(notice, now: @now)
        return if phase.nil?

        case phase
        when :pre_expiration then deliver_reminder!(notice, :pre_expiration)
        when :expiration then deliver_expiration!(notice)
        when :final then deliver_reminder!(notice, :final)
        when :overdue then deliver_reminder!(notice, :overdue)
        end
      end
    end

    def deliver_expiration!(notice)
      notice.expire!
      notice.record_journal_entry!('parking_notice_expired') if notice.user.present?
      deliver_reminder!(notice, :expiration)
    end

    def deliver_reminder!(notice, phase)
      template_key = notice.template_key_for_reminder_phase(phase)
      return if template_key.blank?

      result = notice.enqueue_notification!(template_key)
      return if result.nil?

      self.class.record_delivery!(notice, phase, at: @now) if result.is_a?(QueuedMail::ImmediateDelivery)
    rescue StandardError => e
      Rails.logger.error(
        "[NotifyParkingNotices] notice_id=#{notice.id} phase=#{phase} failed: #{e.class}: #{e.message}"
      )
    end
  end
end
