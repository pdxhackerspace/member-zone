# The training-resource digest is capped by a single interval. It is not one of the
# three-number reminder sequences, so its card and its description say so.
module ReminderSettingDigest
  extend ActiveSupport::Concern

  class_methods do
    def digest?(key)
      ReminderSetting::CATALOG.dig(key.to_s, :digest) == true
    end
  end

  def digest?
    self.class.digest?(key)
  end

  def cadence_description
    return "At most every #{interval_days} #{'day'.pluralize(interval_days)}" if digest?

    schedule.description
  end
end
