module Reminders
  # Prose naming the visits a lapsed access reminder covers, for the email's {{access_summary}}.
  #
  # The reminder used to assert flatly that the member badged in "yesterday". A configurable
  # lookback window makes that false for anything older than a day, and even at the default a
  # visit earlier the same morning is caught by the 8:05 AM run. Naming the real days keeps the
  # sentence honest at any window, and telling a member they were here six times is more use to
  # them than telling them they were here.
  class LapsedAccessVisits
    # Shown when the visits behind the reminder can no longer be identified, matching the
    # vagueness +lapsed_at+ falls back to.
    UNKNOWN = 'recently'.freeze

    def self.summary(user, access_log_ids: nil, now: Time.current)
      new(user, access_log_ids: access_log_ids, now: now).summary
    end

    def initialize(user, access_log_ids: nil, now: Time.current)
      @user = user
      @access_log_ids = access_log_ids
      @now = now
    end

    def summary
      dates = visit_dates
      return UNKNOWN if dates.empty?
      return day_phrase(dates.first) if visit_count == 1
      return "#{visit_count} times #{day_phrase(dates.first)}" if dates.one?

      "#{visit_count} times between #{date_phrase(dates.first)} and #{date_phrase(dates.last)}"
    end

    private

    attr_reader :user, :access_log_ids, :now

    def visit_count
      visit_times.size
    end

    def visit_dates
      visit_times.map(&:to_date).uniq
    end

    def visit_times
      @visit_times ||= logs.order(:logged_at).pluck(:logged_at).compact.map(&:in_time_zone)
    end

    # Named ids win: a message held for review must keep describing the visits it was written
    # for, not whatever the window covers by the time an admin approves it.
    def logs
      return AccessLog.where(user_id: user.id, id: access_log_ids) if access_log_ids.present?

      unnotified = LapsedAccessEligibility.unnotified_access_logs(user, now: now)
      return unnotified if unnotified.exists?

      # Regenerating or previewing a message after its visits were stamped still has real visits
      # to describe.
      AccessLog.where(user_id: user.id, logged_at: LapsedAccessEligibility.window(now: now))
    end

    def day_phrase(date)
      today = now.to_date
      return 'today' if date == today
      return 'yesterday' if date == today - 1

      "on #{date_phrase(date)}"
    end

    def date_phrase(date)
      date.strftime(date.year == now.year ? '%B %-d' : '%B %-d, %Y')
    end
  end
end
