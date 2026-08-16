module Reports
  # The full list of reports, grouped for navigation.
  class Catalog
    CATEGORIES = {
      'data-quality' => 'Data quality',
      'billing' => 'Billing',
      'access' => 'Building access',
      'slack' => 'Slack'
    }.freeze

    # Ordering members by name has to be table-qualified: several of these reports join
    # tables that also have a `username` column, and the bare `ordered_by_display_name`
    # scope is ambiguous once that happens.
    NAME_ORDER = Arel.sql(
      "LOWER(COALESCE(NULLIF(users.full_name, ''), NULLIF(users.email, ''), users.authentik_id)) ASC"
    )

    REPORTS = [
      Definition.new(
        key: 'membership-status-unknown',
        title: 'Legacy records never matched to a membership',
        description: 'Imported rows that were never reconciled against a real member — they have ' \
                     'no access and nothing is chasing them for dues. Every other member has a ' \
                     'determined state: no payments means inactive, not undetermined.',
        category: 'data-quality',
        partial: 'user_table',
        locals: { show_payment_type: true },
        empty_message: 'Every imported record has been matched to a membership.',
        attention: true
      ) do
        ScopeQuery.new(User.membership_undetermined.non_service_accounts.legacy.order(NAME_ORDER))
      end,

      Definition.new(
        key: 'payment-type-unknown',
        title: 'Payment type unknown',
        description: 'Active members with no recorded way of paying their dues — nobody is billing them ' \
                     'and nothing will chase them. Sponsored members are not here: somebody else covers ' \
                     'them, and their payment type says so.',
        category: 'data-quality',
        partial: 'user_table',
        locals: { show_payment_type: true },
        empty_message: 'Every active member has a known payment type.'
      ) do
        BuildingAccessScopeQuery.new(
          User.where(payment_type: 'unknown', active: true).non_service_accounts.order(NAME_ORDER)
        )
      end,

      Definition.new(
        key: 'no-email',
        title: 'Members with no email',
        description: 'Current members with no email address on file, so nothing can be sent to them.',
        category: 'data-quality',
        partial: 'simple_user_table',
        locals: { columns: %i[membership_status] },
        empty_message: 'Every current member has an email address.'
      ) do
        ScopeQuery.new(
          User.where(email: [nil, '']).access_granting
              .non_service_accounts.non_legacy.order(NAME_ORDER)
        )
      end,

      Definition.new(
        key: 'dues-status-lapsed',
        title: 'Dues lapsed',
        description: 'Members who are behind on dues but still inside their grace period. ' \
                     'Members still waiting on their building access orientation are left out — ' \
                     'they are on the awaiting-orientation report instead.',
        category: 'billing',
        partial: 'user_table',
        locals: { show_last_payment: true, show_approved: true },
        empty_message: 'No member is behind on dues.'
      ) { DuesLapsedQuery.new },

      Definition.new(
        key: 'sponsored-and-paying',
        title: 'Sponsored and paying',
        description: 'Members flagged as sponsored whose membership state says otherwise — ' \
                     'usually a billing mistake.',
        category: 'billing',
        partial: 'simple_user_table',
        locals: { columns: %i[membership_status] },
        empty_message: 'No sponsored member is also paying.',
        attention: true
      ) do
        ScopeQuery.new(
          User.where(is_sponsored: true).where.not(membership_state: 'sponsored_member')
              .non_service_accounts.non_legacy.order(NAME_ORDER)
        )
      end,

      Definition.new(
        key: 'awaiting-orientation',
        title: 'Approved members awaiting orientation',
        description: 'Members whose membership was approved but who have not been through ' \
                     'building access orientation, so no key can be issued to them yet — ' \
                     'including anyone paying, or behind on dues, who has still never come in.',
        category: 'access',
        partial: 'awaiting_orientation_table',
        empty_message: 'Every approved member has been through building access orientation.',
        attention: true
      ) { AwaitingOrientationQuery.new },

      Definition.new(
        key: 'lapsed-with-access',
        title: 'Lapsed members with building access',
        description: 'Members whose dues lapsed but who have badged in since their last payment.',
        category: 'access',
        partial: 'lapsed_access_table',
        empty_message: 'No lapsed member has badged in since their last payment.',
        attention: true
      ) { LapsedWithAccessQuery.new },

      Definition.new(
        key: 'legacy-with-access',
        title: 'Legacy members with access records',
        description: 'Members archived as legacy who still have building access history.',
        category: 'access',
        partial: 'legacy_access_table',
        empty_message: 'No legacy member has access records.'
      ) { LegacyAccessQuery.new },

      Definition.new(
        key: 'legacy-recent-access',
        title: 'Legacy members who badged in recently',
        description: 'Members archived as legacy who have badged in within the last year.',
        category: 'access',
        partial: 'legacy_access_table',
        empty_message: 'No legacy member has badged in this year.',
        attention: true
      ) { LegacyAccessQuery.new(since: 1.year.ago, recent_access_limit: 10) },

      Definition.new(
        key: 'inactive-with-rfid',
        title: 'Inactive members with key fobs',
        description: 'Deactivated members who still hold a key fob, and would keep building access ' \
                     'if inactive-member syncing were turned off.',
        category: 'access',
        partial: 'simple_user_table',
        locals: { columns: %i[membership_status rfids] },
        empty_message: 'No inactive member holds a key fob.',
        attention: true
      ) do
        ids = User.where(active: false).non_service_accounts.where.associated(:rfids).distinct.pluck(:id)
        ScopeQuery.new(User.where(id: ids).includes(:rfids, :membership_plan).order(NAME_ORDER))
      end,

      Definition.new(
        key: 'no-access',
        title: 'Paying members who rarely badge in',
        description: 'Paying members with fewer than three access records — they may not be getting ' \
                     'what they pay for.',
        category: 'access',
        partial: 'simple_user_table',
        locals: { columns: %i[membership_status] },
        empty_message: 'Every paying member badges in regularly.'
      ) do
        ids = User.dues_current.non_service_accounts.non_legacy
                  .left_joins(:access_logs).group('users.id')
                  .having('COUNT(access_logs.id) < 3').pluck('users.id')
        ScopeQuery.new(User.where(id: ids).order(NAME_ORDER))
      end,

      Definition.new(
        key: 'active-no-slack',
        title: 'Active members with no Slack account',
        description: 'Active members who joined recently and have never been linked to a Slack account.',
        category: 'slack',
        partial: 'simple_user_table',
        locals: { columns: %i[membership_status] },
        empty_message: 'Every recent active member has a linked Slack account.'
      ) do
        ScopeQuery.new(
          Reminders::SlackSignupEligibility.active_without_slack_scope.order(Catalog::NAME_ORDER)
        )
      end,

      Definition.new(
        key: 'lapsed-with-slack',
        title: 'Lapsed members with Slack accounts',
        description: 'Members whose dues lapsed but who still have a Slack account.',
        category: 'slack',
        partial: 'slack_member_table',
        empty_message: 'No lapsed member has a Slack account.'
      ) do
        ScopeQuery.new(
          User.dues_lapsed.non_service_accounts.non_legacy
              .joins(:slack_user).includes(:slack_user).order(NAME_ORDER)
        )
      end,

      Definition.new(
        key: 'legacy-with-slack',
        title: 'Legacy members with Slack accounts',
        description: 'Members archived as legacy who still have a Slack account.',
        category: 'slack',
        partial: 'slack_member_table',
        empty_message: 'No legacy member has a Slack account.'
      ) do
        ScopeQuery.new(
          User.where(legacy: true).non_service_accounts
              .joins(:slack_user).includes(:slack_user).order(NAME_ORDER)
        )
      end,

      Definition.new(
        key: 'lapsed-active-slack',
        title: 'Lapsed members still active on Slack',
        description: 'Members whose dues lapsed but who have posted on Slack since then.',
        category: 'slack',
        partial: 'slack_member_table',
        locals: { show_lapse_date: true },
        empty_message: 'No lapsed member is still active on Slack.',
        attention: true
      ) { LapsedActiveSlackQuery.new },

      Definition.new(
        key: 'legacy-active-slack',
        title: 'Legacy members still active on Slack',
        description: 'Members archived as legacy who still show recent Slack activity.',
        category: 'slack',
        partial: 'slack_member_table',
        empty_message: 'No legacy member is still active on Slack.'
      ) do
        ScopeQuery.new(
          User.where(legacy: true).non_service_accounts
              .joins(:slack_user).where.not(slack_users: { last_active_at: nil })
              .includes(:slack_user).order('slack_users.last_active_at DESC')
        )
      end,

      Definition.new(
        key: 'slack-inactive',
        title: 'Slack users inactive for over a year',
        description: 'Slack accounts that are neither bots nor deactivated but have gone quiet.',
        category: 'slack',
        partial: 'slack_user_table',
        empty_message: 'Every Slack user has been active in the last year.'
      ) do
        ScopeQuery.new(
          SlackUser.human.inactive.includes(:user).order(Arel.sql('COALESCE(last_active_at, created_at) ASC'))
        )
      end
    ].freeze

    BY_KEY = REPORTS.index_by(&:key).freeze

    class << self
      def reports
        REPORTS
      end

      def find(key)
        BY_KEY[key.to_s]
      end

      def grouped
        CATEGORIES.map { |key, label| [label, REPORTS.select { |report| report.category == key }] }
      end

      # One aggregate query per report, so the sidebar and landing page can show live
      # counts without loading a single row. `except` skips a report whose count the
      # caller is about to work out anyway by rendering it.
      def counts(except: nil)
        REPORTS.reject { |report| report.key == except }
               .to_h { |report| [report.key, report.build_query.count] }
      end
    end
  end
end
