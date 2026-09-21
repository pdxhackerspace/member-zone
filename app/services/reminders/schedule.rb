module Reminders
  # The cadence every reminder shares. Three numbers on ReminderSetting describe it: the first
  # reminder goes out +start_offset_days+ from the subject's anchor, each one after that
  # +interval_days+ after the last one that actually sent, and the sequence stops once
  # +max_reminders+ have gone out. A nil maximum repeats for as long as the subject stays
  # eligible, which is what most reminders want.
  #
  # The anchor is whatever timestamp a reminder counts from — the day a member was approved,
  # the day their dues lapsed, the day a permit expires — and each eligibility service supplies
  # its own. A negative offset sends ahead of the anchor, which is how parking warns people
  # before their notice runs out.
  #
  # Intervals count from the last send rather than from the anchor deliberately. A run that
  # was skipped, or mail that sat in the review queue for a week, pushes the rest of the
  # sequence back instead of firing several reminders in a row to catch up.
  class Schedule
    Progress = Struct.new(:sent_count, :first_sent_at, :last_sent_at, keyword_init: true)
    NOTHING_SENT = Progress.new(sent_count: 0, first_sent_at: nil, last_sent_at: nil).freeze

    def self.for(reminder_key)
      new(ReminderSetting.for_key(reminder_key))
    end

    def initialize(setting)
      @setting = setting
    end

    attr_reader :setting

    delegate :key, :start_offset_days, :interval_days, :max_reminders, :unlimited_reminders?, to: :setting

    def due?(subject, anchor:, now: Time.current)
      at = next_due_at(subject, anchor: anchor)
      at.present? && at <= now
    end

    # When the subject's next reminder may go out, or nil when none is coming: nothing to count
    # from, or the maximum has already been sent.
    def next_due_at(subject, anchor:)
      return nil if anchor.blank?

      progress = progress_for(subject, anchor: anchor)
      return nil if exhausted?(progress.sent_count)
      return anchor + start_offset_days.days if progress.sent_count.zero?

      (progress.last_sent_at || anchor) + interval_days.days
    end

    def exhausted?(sent_count)
      !unlimited_reminders? && sent_count >= max_reminders
    end

    # True when the reminder about to go out is the last one the sequence will send. Parking
    # uses it to pick its final-notice template; with no maximum set there is no last one.
    def final_send?(subject, anchor:)
      return false if unlimited_reminders?

      progress_for(subject, anchor: anchor).sent_count == max_reminders - 1
    end

    # How far through the sequence the subject is. A recorded anchor that no longer matches the
    # one being asked about means the sequence has restarted, so the old count does not apply:
    # a member who paid up and fell behind again is at reminder one.
    def progress_for(subject, anchor: nil)
      progress_from(ReminderDelivery.state_for(key, subject), anchor: anchor)
    end

    # The same reading from a row the caller already has. Admin pages load a page of
    # deliveries in one query, and they have to apply the restart rule too or the due list
    # credits somebody with the sends from a sequence that is over.
    def progress_from(delivery, anchor: nil)
      return NOTHING_SENT if delivery.nil? || delivery.restarted_by?(anchor)

      Progress.new(sent_count: delivery.sent_count, first_sent_at: delivery.first_sent_at,
                   last_sent_at: delivery.last_sent_at)
    end

    def sent_count(subject, anchor: nil)
      progress_for(subject, anchor: anchor).sent_count
    end

    def last_sent_at(subject, anchor: nil)
      progress_for(subject, anchor: anchor).last_sent_at
    end

    def record_send!(subject, anchor:, at: Time.current)
      ReminderDelivery.record!(key, subject, anchor: anchor, at: at)
    end

    # "5 days after the dues date, then every 7 days, up to 3 reminders" — the admin page's
    # description of the cadence, assembled from the same numbers the job runs on.
    def description
      [first_send_phrase, repeat_phrase, limit_phrase].join(', ')
    end

    private

    def first_send_phrase
      anchor = setting.anchor_description
      return "On #{anchor}" if start_offset_days.zero?
      return "#{pluralized_days(start_offset_days.abs)} before #{anchor}" if start_offset_days.negative?

      "#{pluralized_days(start_offset_days)} after #{anchor}"
    end

    def repeat_phrase
      return 'then daily' if interval_days == 1

      "then every #{pluralized_days(interval_days)}"
    end

    def limit_phrase
      return 'with no limit' if unlimited_reminders?

      "up to #{max_reminders} #{'reminder'.pluralize(max_reminders)}"
    end

    def pluralized_days(days)
      "#{days} #{'day'.pluralize(days)}"
    end
  end
end
