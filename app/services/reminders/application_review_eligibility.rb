module Reminders
  class ApplicationReviewEligibility
    INITIAL_DELAY = 1.week
    REPEAT_DELAY = 3.days

    def self.remindable_statuses
      setting = ReminderSetting.find_by(key: 'application_review')
      if setting&.remind_under_review?
        %w[submitted under_review]
      else
        %w[submitted]
      end
    end

    def self.due(now: Time.current)
      stale_cutoff = now - INITIAL_DELAY
      repeat_cutoff = now - REPEAT_DELAY

      base_scope(now: now, stale_cutoff: stale_cutoff)
        .where('application_reminder_sent_at IS NULL OR application_reminder_sent_at <= ?', repeat_cutoff)
        .order(Arel.sql('COALESCE(membership_applications.submitted_at, membership_applications.created_at) ASC'))
    end

    def self.count_due(now: Time.current)
      due(now: now).count
    end

    def self.total_awaiting(now: Time.current)
      stale_cutoff = now - INITIAL_DELAY
      base_scope(now: now, stale_cutoff: stale_cutoff).count
    end

    def self.due?(application, now: Time.current)
      return false unless application.status.in?(remindable_statuses)

      stale_cutoff = now - INITIAL_DELAY
      repeat_cutoff = now - REPEAT_DELAY

      application_age_start(application) <= stale_cutoff &&
        (application.application_reminder_sent_at.nil? ||
          application.application_reminder_sent_at <= repeat_cutoff)
    end

    def self.application_age_start(application)
      application.submitted_at || application.created_at
    end

    def self.base_scope(now:, stale_cutoff: now - INITIAL_DELAY)
      MembershipApplication
        .where(status: remindable_statuses)
        .where(
          'COALESCE(membership_applications.submitted_at, membership_applications.created_at) <= ?',
          stale_cutoff
        )
    end

    private_class_method :base_scope
  end
end
