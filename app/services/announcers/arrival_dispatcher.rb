module Announcers
  # Decides which announcers to run for one access log entry and queues a run for each.
  #
  # An arrival is announced only when the member has switched announcements on, still has
  # access, has a name to be announced by, came in through an outside door (AccessLog#arrival?)
  # just now, and the announcer hasn't announced them within its repeat window. The window
  # check and the new run's row are made under a lock on the member, so two scans a second apart
  # (a double tap, two doors in a row) can't both get through.
  #
  # Every decision for a member who has announcements switched on is logged with the reason, so an
  # announcer that stays quiet can be explained from the logs.
  class ArrivalDispatcher
    # A webhook replaying a backlog (a controller coming back online) shouldn't announce people
    # who arrived hours ago.
    STALE_AFTER = 15.minutes

    def self.call(access_log, now: Time.current)
      new(access_log, now).call
    end

    def self.eligible?(user)
      ineligibility(user).nil?
    end

    # Why the member can't be announced at all, or nil when they can.
    def self.ineligibility(user)
      return 'no member matched the entry' if user.nil?
      return 'member has announcements switched off' unless user.announce_arrivals?
      return 'member is a service account' if user.service_account?
      return 'member does not have access' unless user.active?
      return 'member chose not to be greeted' if user.greeting_name.blank?

      nil
    end

    def initialize(access_log, now)
      @access_log = access_log
      @user = access_log.user
      @now = now
    end

    def call
      reason = self.class.ineligibility(@user) || entry_skip_reason
      return skip(reason) if reason

      runs = claim_runs
      runs.each { |run| RunJob.perform_later(run.id) }
      runs
    end

    private

    def entry_skip_reason
      unless AccessLog::ARRIVAL_ACTIONS.include?(@access_log.action.to_s.downcase)
        return "#{@access_log.action.inspect} is not an arrival"
      end
      unless DefaultSetting.arrival_location?(@access_log.location)
        return "#{@access_log.location.inspect} is not one of the outside doors"
      end
      return "entry is older than #{STALE_AFTER.inspect}" unless fresh?

      nil
    end

    def fresh?
      @access_log.logged_at.present? && @access_log.logged_at > @now - STALE_AFTER
    end

    def claim_runs
      @user.with_lock do
        @user.announcers.ordered.filter_map do |announcer|
          reason = announcer_skip_reason(announcer)
          next log("skipped #{announcer.name.inspect}: #{reason}") if reason

          log("queued #{announcer.name.inspect}")
          announcer.announcer_runs.create!(user: @user, access_log: @access_log)
        end
      end
    end

    def announcer_skip_reason(announcer)
      return 'announcer is disabled' unless announcer.enabled?

      recent = announcer.recent_announcement(@user, now: @now)
      return nil if recent.nil?

      "already announced at #{recent.created_at.iso8601} (#{recent.status}); " \
        "repeat window of #{announcer.repeat_after_minutes} minutes ends at " \
        "#{(recent.created_at + announcer.repeat_after).iso8601}"
    end

    # Members who never switched announcements on are skipped quietly: that's most entries, and
    # there's nothing to explain.
    def skip(reason)
      if @user&.announce_arrivals?
        log("not announcing: #{reason}")
      else
        Rails.logger.debug { "Announcers: access log #{@access_log.id}: not announcing: #{reason}" }
      end
      []
    end

    def log(message)
      Rails.logger.info("Announcers: access log #{@access_log.id} (#{@user&.username}): #{message}")
      nil
    end
  end
end
