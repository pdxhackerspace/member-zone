# The parking arrival reminder fires when a member badges in, so its card is a repeat
# window in minutes rather than the three day-counted fields every other reminder uses.
module ReminderSettingArrival
  extend ActiveSupport::Concern

  class_methods do
    def arrival_triggered?(key)
      ReminderSetting::CATALOG.dig(key.to_s, :arrival_triggered) == true
    end
  end

  def arrival_triggered?
    self.class.arrival_triggered?(key)
  end

  def repeat_window_description
    return 'On every arrival' if repeat_after_minutes.zero?

    "On arrival, at most once every #{repeat_after_minutes} minutes"
  end

  def cadence_description
    return repeat_window_description if arrival_triggered?

    schedule.description
  end
end
