module Metrics
  # The roster: how many members there are and what standing they are in.
  class MembersCollector < Collector
    SIGN_IN_WINDOWS = { '24h' => 1.day, '7d' => 7.days, '30d' => 30.days }.freeze

    def collect
      by_state
      totals
      sign_ins
    end

    private

    def members
      User.where(service_account: false)
    end

    def by_state
      gauge('memberzone_members', 'Members by membership state (service accounts excluded).')
        .set_grouped(with_zeros(members.group(:membership_state).count, MembershipState::STATES), :state)
      gauge('memberzone_members_by_payment_type', 'Members by payment type.')
        .set_grouped(members.group(:payment_type).count.transform_keys(&:to_s), :payment_type)
      gauge('memberzone_members_by_dues_status', 'Members by dues status.')
        .set_grouped(members.group(:dues_status).count.transform_keys(&:to_s), :dues_status)
    end

    def totals
      gauge('memberzone_members_active', 'Members whose standing currently counts as active.',
            members.where(active: true).count)
      gauge('memberzone_admins', 'Accounts with the administrator flag.', User.where(is_admin: true).count)
      gauge('memberzone_service_accounts', 'Service accounts (API token holders that are not people).',
            User.where(service_account: true).count)
      gauge('memberzone_members_created_30d', 'Member records created in the last 30 days.',
            members.where(created_at: 30.days.ago..).count)
    end

    def sign_ins
      family = gauge('memberzone_members_signed_in', 'Members who last signed in within the window.')
      SIGN_IN_WINDOWS.each do |window, span|
        family.set(members.where(last_login_at: span.ago..).count, window: window)
      end
    end
  end
end
