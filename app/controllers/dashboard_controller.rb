class DashboardController < AuthenticatedController
  include MemberHomeTabs
  include TrainingHistoryData

  # Dashboard housekeeping item => the report it links to. Adding a report-backed item
  # means adding a line here rather than reimplementing the report's scope.
  REPORT_BACKED_COUNTS = {
    lapsed_with_access: 'lapsed-with-access',
    legacy_recent_access: 'legacy-recent-access',
    lapsed_with_slack: 'lapsed-with-slack',
    legacy_with_slack: 'legacy-with-slack',
    lapsed_active_slack: 'lapsed-active-slack',
    legacy_active_slack: 'legacy-active-slack',
    slack_inactive: 'slack-inactive',
    no_email: 'no-email'
  }.freeze

  before_action -> { require_privilege!(:'dashboard.admin') }

  def index
    @home_user = true_user || current_user
    @active_tab = params[:tab]&.to_sym || :admin_dashboard

    @user_count = User.non_legacy.count
    @active_user_count = User.non_legacy.active.count
    @inactive_user_count = User.non_legacy.where(active: false).count
    @legacy_user_count = User.legacy.count
    @last_synced_at = User.maximum(:last_synced_at)
    @sheet_entry_count = SheetEntry.count
    @active_slack_user_count = SlackUser.human.active.count
    @slack_user_count = SlackUser.count
    @paypal_payment_count = PaypalPayment.count
    @recharge_payment_count = RechargePayment.count

    # Count members on manual plans
    manual_plan_ids = MembershipPlan.manual.pluck(:id)
    @manual_payment_member_count = if manual_plan_ids.any?
                                     User.where(membership_plan_id: manual_plan_ids).count +
                                       UserSupplementaryPlan
                                       .where(membership_plan_id: manual_plan_ids)
                                       .select(:user_id).distinct.count
                                   else
                                     0
                                   end

    @queued_mail_count = QueuedMail.pending.count

    prepare_attention_items
    @application_backlog = MembershipApplications::Backlog.call if can?(:'applications.view')

    # Highlighted journal entries from the last 2 weeks
    @recent_highlights = Journal.highlighted
                                .includes(:user, :actor_user)
                                .where(changed_at: 2.weeks.ago..)
                                .order(changed_at: :desc)
                                .limit(50)

    prepare_member_home_tabs_data
    load_completed_training_requests(@home_user)
    load_training_history(@home_user) if @active_tab == :training_history
  end

  private

  def prepare_attention_items
    assign_urgent_attention_items

    # Urgent: Unlinked Recharge payments
    @unlinked_recharge_count = RechargePayment.where(user_id: nil, dont_link: false).count

    # Important: Open and draft incident reports
    @open_incident_count = IncidentReport.where(status: 'in_progress').count
    @draft_incident_count = IncidentReport.where(status: 'draft').count
    @active_incident_count = @open_incident_count + @draft_incident_count

    # Important: Email templates needing review
    @templates_needing_review_count = EmailTemplate.needs_review.count

    # Important: Member-suggested interests needing review
    @interests_needing_review_count = Interest.needs_review.count

    # Pending membership applications (open or under review); stale ones (>1 week) are urgent on the dashboard
    @pending_applications_count = MembershipApplication.pending.count
    @stale_applications_count = MembershipApplication.stale_pending.count
    @submitted_applications_count = MembershipApplication.submitted_apps.count
    @under_review_applications_count = MembershipApplication.under_review_apps.count

    # Important: Parking notices
    @active_parking_permit_count = ParkingNotice.permits.active_notices.count
    @active_parking_ticket_count = ParkingNotice.tickets.active_notices.count
    @active_parking_count = @active_parking_permit_count + @active_parking_ticket_count
    @expired_parking_permit_count = ParkingNotice.permits.expired_notices.count
    @expired_parking_ticket_count = ParkingNotice.tickets.expired_notices.count
    @expired_parking_count = @expired_parking_permit_count + @expired_parking_ticket_count

    # Important: Manual / cash / personal payment plans — overdue, due today, or due within configured "soon" window
    @manual_payments_due_count = manual_payments_due_member_count

    # Housekeeping items that link straight through to a report. Both the number here
    # and the total on the destination page come from the same catalog entry, so they
    # cannot drift apart — and the report queries are set-based, where the copies these
    # replaced walked every matching member one at a time.
    assign_report_counts

    @ai_ollama_unconfigured = @ai_ollama_profiles.any? { |p| p.enabled? && p.effective_base_url.blank? }

    @emergency_active_override_count = User.non_service_accounts.where(emergency_active_override: true).count

    @dashboard_attention_items = build_dashboard_attention_items
  end

  def assign_report_counts
    @report_counts = REPORT_BACKED_COUNTS.transform_values do |key|
      Reports::Catalog.find(key).build_query.count
    end

    @report_counts.each { |name, count| instance_variable_set(:"@#{name}_count", count) }
  end

  def assign_urgent_attention_items
    urgent = AdminDashboard::UrgentItems.snapshot(user: @home_user)
    @admin_unread_messages_count = urgent.unread_messages_count
    @ac_offline_count = urgent.ac_offline_count
    @ac_sync_failed_count = urgent.ac_sync_failed_count
    @ac_backup_failed_count = urgent.ac_backup_failed_count
    @ac_issue_count = urgent.ac_issue_count
    @payment_processors_sync_unhealthy = urgent.payment_processors_sync_unhealthy
    @authentik_member_source = urgent.authentik_member_source
    @authentik_api_urgent = urgent.authentik_api_urgent
    @authentik_sync_issue = urgent.authentik_sync_issue
    @mailer_health = urgent.mailer_health
    @ai_ollama_profiles = urgent.ai_ollama_profiles
    @ai_ollama_urgent = urgent.ai_ollama_urgent
    @printers = urgent.printers
    @unhealthy_printers = urgent.unhealthy_printers
  end

  def build_dashboard_attention_items
    [
      { tier: :urgent, id: :unread_messages, ok: @admin_unread_messages_count.zero? },
      { tier: :urgent, id: :ac_issues, ok: @ac_issue_count.zero? },
      { tier: :urgent, id: :payment_processors, ok: @payment_processors_sync_unhealthy.empty? },
      { tier: :urgent, id: :authentik, ok: authentik_dashboard_ok? },
      { tier: :urgent, id: :mailer_health, ok: @mailer_health.healthy? },
      { tier: :urgent, id: :ai_ollama, ok: !@ai_ollama_urgent },
      { tier: :urgent, id: :printers, ok: @unhealthy_printers.empty? },
      {
        tier: @stale_applications_count.positive? ? :urgent : :important,
        id: :membership_applications,
        ok: @pending_applications_count.zero?
      },
      { tier: :important, id: :unlinked_recharge, ok: @unlinked_recharge_count.zero? },
      { tier: :important, id: :mail_queue, ok: @queued_mail_count.zero? },
      { tier: :important, id: :ai_ollama_unconfigured, ok: !@ai_ollama_unconfigured },
      { tier: :important, id: :incidents, ok: @active_incident_count.zero? },
      { tier: :important, id: :email_templates, ok: @templates_needing_review_count.zero? },
      { tier: :important, id: :interests, ok: @interests_needing_review_count.zero? },
      { tier: :important, id: :emergency_active_overrides, ok: @emergency_active_override_count.zero? },
      { tier: :important, id: :parking_active, ok: @active_parking_count.zero? },
      { tier: :important, id: :parking_expired, ok: @expired_parking_count.zero? },
      { tier: :important, id: :manual_payments_due, ok: @manual_payments_due_count.zero? },
      { tier: :housekeeping, id: :lapsed_with_access, ok: @lapsed_with_access_count.zero? },
      { tier: :housekeeping, id: :legacy_recent_access, ok: @legacy_recent_access_count.zero? },
      { tier: :housekeeping, id: :lapsed_with_slack, ok: @lapsed_with_slack_count.zero? },
      { tier: :housekeeping, id: :legacy_with_slack, ok: @legacy_with_slack_count.zero? },
      { tier: :housekeeping, id: :lapsed_active_slack, ok: @lapsed_active_slack_count.zero? },
      { tier: :housekeeping, id: :legacy_active_slack, ok: @legacy_active_slack_count.zero? },
      { tier: :housekeeping, id: :slack_inactive, ok: @slack_inactive_count.zero? },
      { tier: :housekeeping, id: :no_email, ok: @no_email_count.zero? }
    ].freeze
  end

  # Members on any manual plan (primary or supplementary) whose next dues date falls on or before
  # the end of today + MembershipSetting.manual_payment_due_soon_days. Same window as "Due soon" on
  # Manual Payment Plan Members.
  def manual_payments_due_member_count
    manual_plan_ids = MembershipPlan.manual.pluck(:id)
    return 0 if manual_plan_ids.empty?

    soon_days = MembershipSetting.manual_payment_due_soon_days
    cutoff = (Date.current + soon_days).end_of_day
    due = User.where.not(dues_due_at: nil).where(dues_due_at: ..cutoff)
    primary_ids = due.where(membership_plan_id: manual_plan_ids).pluck(:id)
    supplementary_ids = due.joins(:user_supplementary_plans)
                           .where(user_supplementary_plans: { membership_plan_id: manual_plan_ids })
                           .distinct
                           .pluck(:id)
    (primary_ids + supplementary_ids).uniq.size
  end

  def authentik_dashboard_ok?
    return false if @authentik_api_urgent
    return true if @authentik_member_source.nil? || !@authentik_member_source.enabled?
    return false if @authentik_sync_issue

    true
  end
end
