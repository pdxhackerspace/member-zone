module Reports
  # Members whose dues have lapsed but who have badged in since their last payment.
  #
  # Previously this walked every lapsed member and issued four queries each (three for
  # the last payment date, one for the access logs). It is now five queries in total,
  # independent of member count.
  class LapsedWithAccessQuery < BaseQuery
    RECENT_ACCESS_LIMIT = 5

    def count
      entries.size
    end

    def relation
      ordered_by_ids(entries.keys)
    end

    # user_id => { last_payment_date:, access_count:, most_recent_at: }, most recent access first
    def entries
      @entries ||= build_entries
    end

    def page_locals(users)
      cutoffs = users.to_h { |user| [user.id, last_payment_dates[user.id]&.end_of_day] }
      {
        metadata: entries,
        recent_accesses: AccessLogAggregates.new(cutoffs).recent(limit: RECENT_ACCESS_LIMIT)
      }
    end

    private

    def candidates
      @candidates ||= User.dues_lapsed
                          .non_service_accounts
                          .non_legacy
                          .pluck(:id, :last_payment_date, :recharge_most_recent_payment_date)
    end

    def last_payment_dates
      @last_payment_dates ||= LastPaymentDates.for(candidates)
    end

    def build_entries
      cutoffs = last_payment_dates.transform_values(&:end_of_day)
      totals = AccessLogAggregates.new(cutoffs).totals

      matched = totals.select { |_user_id, row| row[:access_count].positive? }
      ranked = matched.sort_by { |_user_id, row| row[:most_recent_at] }.reverse

      ranked.to_h do |user_id, row|
        [user_id, row.merge(last_payment_date: last_payment_dates[user_id])]
      end
    end
  end
end
