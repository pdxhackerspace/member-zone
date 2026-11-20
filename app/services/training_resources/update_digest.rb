module TrainingResources
  # One email per person, at most once per interval, covering every topic they
  # train or are trained in. The interval is global: a new batch of changes waits
  # rather than sending its own email.
  class UpdateDigest
    DELIVERABLE_EMAIL_SQL = "users.email IS NOT NULL AND users.email ~ '\\S'".freeze

    def self.call(now: Time.current, force: false)
      new(now: now, force: force).call
    end

    def self.summary(now: Time.current)
      new(now: now).summary
    end

    def initialize(now:, force: false)
      @now = now
      @force = force
    end

    def call
      return unless ReminderSetting.enabled?(REMINDER_KEY)
      return if pending.empty?
      return unless @force || due?

      stamp(pending.map(&:id)) if deliver.zero?
    end

    def summary
      DigestSummary.new(
        pending_count: pending.size,
        topic_count: pending.map(&:training_topic_id).uniq.size,
        due_recipient_count: due_recipient_count,
        due: due?,
        next_digest_at: next_digest_at
      )
    end

    private

    def deliver
      failures = 0
      mailed = mailed_change_ids
      holds = membership_holds
      recipients.find_each { |user| failures += 1 unless deliver_to(user, mailed, holds) }
      failures
    end

    def deliver_to(user, mailed, holds)
      entries = entries_for(user, holds)
      ids = entries.flat_map(&:source_ids).uniq - mailed[user.id].to_a
      return true if ids.empty?

      send_one(user, entries.select { |entry| entry.source_ids.intersect?(ids) }, ids)
    end

    def send_one(user, entries, ids)
      presented = DigestPresenter.new(entries)
      QueuedMail.enqueue(
        MAILER_ACTION.to_sym, user,
        reason: "Training resources updated: #{presented.topic_names}",
        change_ids: ids,
        update_count: presented.count_phrase,
        updated_topics: presented.topic_names,
        resource_updates_html: presented.html,
        resource_updates_text: presented.text,
        profile_url: MemberMailer.profile_url_for(user)
      )
      true
    rescue StandardError => e
      Rails.logger.error("[UpdateDigest] user_id=#{user.id} #{e.class}: #{e.message}")
      false
    end

    def due_recipient_count
      return 0 if pending.empty? || !due?

      holds = membership_holds
      recipients.count { |user| entries_for(user, holds).any? }
    end

    def entries_for(user, holds)
      visible = pending.select { |change| visible_to?(user, change, holds) }
      ChangeCollapser.entries(visible)
    end

    def visible_to?(user, change, holds)
      since = holds[[user.id, change.training_topic_id]]
      since.present? && change.occurred_at >= since
    end

    def membership_holds
      holds = {}
      remember_holds(holds, Training.where(trainee_id: recipient_ids, training_topic_id: topic_ids),
                     :trainee_id, :trained_at)
      remember_holds(holds, TrainerCapability.where(user_id: recipient_ids, training_topic_id: topic_ids),
                     :user_id, :created_at)
      holds
    end

    def remember_holds(holds, relation, user_column, time_column)
      relation.pluck(user_column, :training_topic_id, time_column).each do |user_id, topic_id, at|
        key = [user_id, topic_id]
        holds[key] = [holds[key], at].compact.min
      end
    end

    def mailed_change_ids
      rows = QueuedMail.where(mailer_action: MAILER_ACTION, recipient_id: recipients.select(:id))
                       .pluck(:recipient_id, :mailer_args)
      rows.each_with_object(Hash.new { |map, key| map[key] = Set.new }) do |(user_id, args), map|
        Array(args.is_a?(Hash) ? args['change_ids'] : nil).each { |id| map[user_id] << id.to_i }
      end
    end

    def recipients
      @recipients ||= begin
        scope = User.access_granting.non_service_accounts.where(id: holder_ids).where(DELIVERABLE_EMAIL_SQL)
        Notifications::EligibilityOptOuts.user_scope_excluding_opt_outs(scope, REMINDER_KEY)
      end
    end

    def holder_ids
      Training.where(training_topic_id: topic_ids).distinct.pluck(:trainee_id) |
        TrainerCapability.where(training_topic_id: topic_ids).distinct.pluck(:user_id)
    end

    def recipient_ids
      @recipient_ids ||= recipients.pluck(:id)
    end

    def topic_ids
      @topic_ids ||= pending.map(&:training_topic_id).uniq
    end

    def pending
      @pending ||= TrainingResourceChange.pending.includes(:training_topic).order(:occurred_at, :id).to_a
    end

    def due?
      last_digest_at.nil? || last_digest_at <= @now - interval_days.days
    end

    def next_digest_at
      return @now if last_digest_at.nil?

      last_digest_at + interval_days.days
    end

    def last_digest_at
      return @last_digest_at if defined?(@last_digest_at)

      @last_digest_at = [stamped_at, queued_at].compact.max
    end

    # A queued digest starts the interval even when another recipient failed, so the
    # people who already received it do not get the next day's edits early. Unstamped
    # rows stay pending and go out on the next interval to whoever missed them.
    def stamped_at
      TrainingResourceChange.where.not(notified_at: nil).maximum(:notified_at)
    end

    def queued_at
      QueuedMail.where(mailer_action: MAILER_ACTION).maximum(:created_at)
    end

    def interval_days
      ReminderSetting.for_key(REMINDER_KEY).interval_days
    end

    def stamp(ids)
      TrainingResourceChange.where(id: ids).update_all(notified_at: @now, updated_at: @now)
    end
  end
end
