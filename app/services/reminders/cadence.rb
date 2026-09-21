module Reminders
  # Extended by the eligibility services. Each one names its reminder key and says what its
  # subjects count from; everything about when the next reminder is due, how many have gone
  # out, and how to record one comes from here.
  #
  #   class OrientationEligibility
  #     extend Cadence
  #
  #     def self.reminder_key = 'orientation'
  #     def self.anchor(user) = user.membership_approved_at
  #   end
  module Cadence
    def schedule
      Schedule.for(reminder_key)
    end

    def reminder_setting
      ReminderSetting.for_key(reminder_key)
    end

    def reminder_enabled?
      ReminderSetting.enabled?(reminder_key)
    end

    # Whether the cadence alone says this subject is due. Callers add their own domain
    # conditions — is the member still overdue, is the notice still uncleared — around it.
    def cadence_due?(subject, now: Time.current)
      schedule.due?(subject, anchor: anchor(subject), now: now)
    end

    def next_due_at(subject)
      schedule.next_due_at(subject, anchor: anchor(subject))
    end

    def reminders_sent(subject)
      schedule.sent_count(subject, anchor: anchor(subject))
    end

    # Counts one reminder as sent against this subject's sequence. Called once the mail has
    # actually left: mail held for review has not reached anyone, so it must not move the clock.
    def record_delivery!(subject, at: Time.current)
      ReminderDelivery.record!(reminder_key, subject, anchor: anchor(subject), at: at)
    end
  end
end
