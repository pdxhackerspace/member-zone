module Reports
  # Members whose dues have lapsed but who are still posting on Slack.
  #
  # The lapse date is the recorded end of membership when there is one, and otherwise
  # the last payment we can find — resolved for the whole set at once rather than
  # three queries per member.
  class LapsedActiveSlackQuery < BaseQuery
    def count
      entries.size
    end

    def relation
      ordered_by_ids(entries.keys).includes(:slack_user)
    end

    # user_id => { lapse_date:, last_slack_active: }, most recently active on Slack first
    def entries
      @entries ||= build_entries
    end

    def page_locals(_users)
      { metadata: entries }
    end

    private

    def candidates
      @candidates ||= User.dues_lapsed
                          .non_service_accounts
                          .non_legacy
                          .joins(:slack_user)
                          .where.not(slack_users: { last_active_at: nil })
                          .pluck(:id, :membership_ended_date, :last_payment_date,
                                 :recharge_most_recent_payment_date, 'slack_users.last_active_at')
    end

    def build_entries
      needs_payment_lookup = candidates.reject { |row| row[1] }.map { |row| [row[0], row[2], row[3]] }
      payment_dates = LastPaymentDates.for(needs_payment_lookup)

      matched = candidates.filter_map do |user_id, ended_on, _last_payment, _recharge_recent, slack_active|
        lapse_date = ended_on || payment_dates[user_id]
        next if lapse_date.blank?
        next unless slack_active > lapse_date.to_time.end_of_day

        [user_id, { lapse_date: lapse_date, last_slack_active: slack_active }]
      end

      matched.sort_by { |_user_id, row| row[:last_slack_active] }.reverse.to_h
    end
  end
end
