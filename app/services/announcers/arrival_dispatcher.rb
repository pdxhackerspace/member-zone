module Announcers
  # Decides which announcers to run for one access log entry and queues a run for each.
  #
  # An arrival is announced only when the member has switched announcements on, still has
  # access, has a name to be announced by, came in through an outside door (AccessLog#arrival?)
  # just now, and the announcer hasn't announced them within its repeat window. The window
  # check and the new run's row are made under a lock on the member, so two scans a second apart
  # (a double tap, two doors in a row) can't both get through.
  class ArrivalDispatcher
    # A webhook replaying a backlog (a controller coming back online) shouldn't announce people
    # who arrived hours ago.
    STALE_AFTER = 15.minutes

    def self.call(access_log, now: Time.current)
      new(access_log, now).call
    end

    def self.eligible?(user)
      user.present? && user.announce_arrivals? && !user.service_account? && user.active? &&
        user.greeting_name.present?
    end

    def initialize(access_log, now)
      @access_log = access_log
      @user = access_log.user
      @now = now
    end

    def call
      return [] unless self.class.eligible?(@user) && @access_log.arrival? && fresh?

      runs = claim_runs
      runs.each { |run| RunJob.perform_later(run.id) }
      runs
    end

    private

    def fresh?
      @access_log.logged_at.present? && @access_log.logged_at > @now - STALE_AFTER
    end

    def claim_runs
      @user.with_lock do
        @user.announcers.enabled.ordered.filter_map do |announcer|
          next if announcer.announced_recently?(@user, now: @now)

          announcer.announcer_runs.create!(user: @user, access_log: @access_log)
        end
      end
    end
  end
end
