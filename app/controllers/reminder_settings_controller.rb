class ReminderSettingsController < AdminController
  include Pagy::Method

  PER_PAGE = 50

  RUNNERS = {
    'slack_signup' => Reminders::NotifySlackSignup,
    'application_link' => Reminders::NotifyApplicationLink,
    'payment_overdue' => Reminders::NotifyPaymentOverdue,
    'orientation' => Reminders::NotifyOrientation,
    'parking_notices' => Reminders::NotifyParkingNotices,
    'lapsed_access' => Reminders::NotifyLapsedAccess,
    'staff_application' => MembershipApplications::NotifyDirectorsOfStaleApplications
  }.freeze

  # The one template that headlines each reminder's card, where its own list of templates is
  # longer than one.
  HEADLINE_TEMPLATE_KEYS = {
    'slack_signup' => 'slack_signup_reminder',
    'application_link' => 'application_link_reminder',
    'payment_overdue' => 'payment_past_due',
    'orientation' => 'orientation_reminder',
    'parking_notices' => 'parking_permit_expiring_soon',
    'lapsed_access' => 'lapsed_access_reminder',
    'staff_application' => 'staff_application_reminder'
  }.freeze

  before_action :set_reminder_setting, only: %i[show update send_now]

  def index
    ReminderSetting.seed_defaults!
    ReminderSetting.sync_catalog_attributes!
    @reminder_settings = ReminderSetting.ordered
    @enabled_count = @reminder_settings.count(&:enabled?)
    load_index_email_templates
    @reminder_counts = index_counts
    @slack_source_enabled = MemberSource.enabled?('slack')
    @building_access_topic = TrainingTopic.building_access
    @membership_setting = MembershipSetting.instance
  end

  def show
    load_show_data
  end

  def update
    if @reminder_setting.update(reminder_setting_params)
      redirect_to reminder_settings_path, notice: "#{@reminder_setting.name} updated."
    else
      # The edit controls live on the index cards, which the show page does not render, so the
      # errors have to travel back to the index rather than into a form.
      problems = @reminder_setting.errors.full_messages.to_sentence
      redirect_to reminder_settings_path, alert: "#{@reminder_setting.name} not updated — #{problems}."
    end
  end

  def send_now
    runner = RUNNERS[@reminder_setting.key]
    unless runner
      redirect_to reminder_settings_path, alert: 'Unknown reminder type.'
      return
    end

    blocked = send_now_blocked_reason(@reminder_setting)
    if blocked
      redirect_to reminder_settings_path, alert: blocked
      return
    end

    runner.call
    redirect_to reminder_settings_path, notice: "#{@reminder_setting.name} run finished."
  end

  private

  def set_reminder_setting
    @reminder_setting = ReminderSetting.find_by!(key: params[:key])
  end

  # The cards link to the one template that headlines each reminder as well as to every
  # template the reminder can send, so both shapes are loaded up front.
  def load_index_email_templates
    @reminder_email_templates = ReminderSetting.email_templates_by_reminder_key
    templates = EmailTemplate.where(key: HEADLINE_TEMPLATE_KEYS.values).index_by(&:key)
    @headline_email_templates = HEADLINE_TEMPLATE_KEYS.transform_values { |key| templates[key] }
  end

  # Every card says the same two things — how many would go out today, and how big the
  # population behind that number is. Only the wording of the second differs.
  def index_counts
    payment_overdue = Reminders::PaymentOverdueEligibility.overdue_counts

    {
      'slack_signup' => slack_signup_counts,
      'application_link' => application_link_counts,
      'payment_overdue' => payment_overdue_counts(payment_overdue),
      'orientation' => orientation_counts,
      'parking_notices' => parking_notice_counts,
      'lapsed_access' => lapsed_access_counts,
      'staff_application' => staff_application_counts
    }
  end

  def slack_signup_counts
    { due: Reminders::SlackSignupEligibility.count_due,
      context: "#{Reminders::SlackSignupEligibility.total_without_slack} active without Slack" }
  end

  def application_link_counts
    { due: Reminders::ApplicationLinkEligibility.count_due,
      context: "#{Reminders::ApplicationLinkEligibility.total_awaiting} awaiting application" }
  end

  def payment_overdue_counts(counts)
    context = "#{counts[:total]} overdue"
    context += ", #{counts[:within_grace]} not yet due a reminder" if counts[:within_grace].positive?

    { due: Reminders::PaymentOverdueEligibility.count_due,
      context: context,
      note: 'The lapse notice shares this switch. It fires when a member becomes inactive rather than on the ' \
            'daily run, so “Send now” does not send it.' }
  end

  def orientation_counts
    { due: Reminders::OrientationEligibility.count_due,
      context: "#{Reminders::OrientationEligibility.total_awaiting} awaiting orientation" }
  end

  def parking_notice_counts
    { due: Reminders::ParkingNoticeEligibility.count_due,
      context: "#{Reminders::ParkingNoticeEligibility.total_awaiting} active or expired, not cleared",
      note: 'Issued emails on creation are always sent and are not controlled by this toggle.' }
  end

  def lapsed_access_counts
    { due: Reminders::LapsedAccessEligibility.count_due,
      context: "#{Reminders::LapsedAccessEligibility.total_accessed_in_window} inactive, badged in during the window",
      note: 'A member is emailed once per batch of visits. Visits already covered by a reminder are never ' \
            'mentioned again.' }
  end

  def staff_application_counts
    { due: Reminders::StaleApplicationEligibility.count_due,
      context: "#{Reminders::StaleApplicationEligibility.total_awaiting} pending review",
      note: 'Sent to directors rather than to the applicant, so members cannot opt out of it.' }
  end

  def reminder_setting_params
    permitted = %i[enabled allow_opt_out start_offset_days interval_days max_reminders]
    permitted << :lookback_days if @reminder_setting.configurable_lookback?
    params.expect(reminder_setting: permitted)
  end

  def send_now_blocked_reason(reminder)
    return "#{reminder.name} is disabled." unless reminder.enabled?

    case reminder.key
    when 'slack_signup'
      'Slack member source is disabled.' unless MemberSource.enabled?('slack')
    when 'application_link'
      unless Reminders::ApplicationLinkEligibility.active?
        'Application link reminders require the built-in membership application.'
      end
    end
  end

  def load_show_data
    @membership_setting = MembershipSetting.instance

    case @reminder_setting.key
    when 'slack_signup' then load_slack_signup_show_data
    when 'application_link' then load_application_link_show_data
    when 'payment_overdue' then load_payment_overdue_show_data
    when 'orientation' then load_orientation_show_data
    when 'parking_notices' then load_parking_notices_show_data
    when 'lapsed_access' then load_lapsed_access_show_data
    when 'staff_application' then load_staff_application_show_data
    end
  end

  def load_slack_signup_show_data
    @pagy, @due_users = pagy(Reminders::SlackSignupEligibility.due, limit: PER_PAGE)
    @slack_due_count = @pagy.count
    @slack_without_slack_count = Reminders::SlackSignupEligibility.total_without_slack
    @slack_source_enabled = MemberSource.enabled?('slack')
    @slack_email_template = EmailTemplate.find_by(key: 'slack_signup_reminder')
    load_delivery_index(@due_users)
  end

  def load_orientation_show_data
    @pagy, @due_users = pagy(Reminders::OrientationEligibility.due, limit: PER_PAGE)
    @orientation_due_count = @pagy.count
    @orientation_awaiting_count = Reminders::OrientationEligibility.total_awaiting
    @orientation_email_template = EmailTemplate.find_by(key: 'orientation_reminder')
    @building_access_topic = TrainingTopic.building_access
    load_delivery_index(@due_users)
  end

  def load_payment_overdue_show_data
    @pagy, @due_users = pagy(Reminders::PaymentOverdueEligibility.due, limit: PER_PAGE)
    @payment_overdue_due_count = @pagy.count
    counts = Reminders::PaymentOverdueEligibility.overdue_counts
    @payment_overdue_total_count = counts[:total]
    @payment_overdue_grace_count = counts[:within_grace]
    @payment_overdue_reminded_count = counts[:total] - counts[:within_grace]
    @payment_overdue_email_template = EmailTemplate.find_by(key: 'payment_past_due')
    @membership_lapsed_email_template = EmailTemplate.find_by(key: 'membership_lapsed')
    load_delivery_index(@due_users)
  end

  def load_lapsed_access_show_data
    @pagy, @due_users = pagy(Reminders::LapsedAccessEligibility.due, limit: PER_PAGE)
    @lapsed_access_due_count = @pagy.count
    @lapsed_access_window_count = Reminders::LapsedAccessEligibility.total_accessed_in_window
    @lapsed_access_email_template = EmailTemplate.find_by(key: 'lapsed_access_reminder')
    @lapsed_access_visit_counts = Reminders::LapsedAccessEligibility.unnotified_access_counts(@due_users.map(&:id))
    load_delivery_index(@due_users)
  end

  def load_parking_notices_show_data
    @pagy, @due_notices = pagy(Reminders::ParkingNoticeEligibility.due, limit: PER_PAGE)
    @parking_due_count = @pagy.count
    @parking_awaiting_count = Reminders::ParkingNoticeEligibility.total_awaiting
    @parking_expiring_soon_template = EmailTemplate.find_by(key: 'parking_permit_expiring_soon')
    load_delivery_index(@due_notices)
  end

  def load_staff_application_show_data
    @pagy, @due_applications = pagy(Reminders::StaleApplicationEligibility.due, limit: PER_PAGE)
    @staff_application_due_count = @pagy.count
    @staff_application_awaiting_count = Reminders::StaleApplicationEligibility.total_awaiting
    @staff_application_email_template = EmailTemplate.find_by(key: 'staff_application_reminder')
    load_delivery_index(@due_applications)
  end

  def load_application_link_show_data
    @application_link_awaiting_count = Reminders::ApplicationLinkEligibility.total_awaiting
    @application_link_email_template = EmailTemplate.find_by(key: 'application_link_reminder')

    unless Reminders::ApplicationLinkEligibility.active?
      @pagy, @due_verifications = pagy(ApplicationVerification.none, limit: PER_PAGE)
      @application_link_due_count = 0
      load_delivery_index(@due_verifications)
      return
    end

    @pagy, @due_verifications = pagy(Reminders::ApplicationLinkEligibility.due, limit: PER_PAGE)
    @application_link_due_count = @pagy.count
    load_delivery_index(@due_verifications)
  end

  # How many reminders each row on the page has already had, in one query rather than per row.
  # The anchors come along because a delivery only counts against the sequence it was recorded
  # under — see ReminderSettingsHelper#reminder_progress_for.
  def load_delivery_index(subjects)
    @reminder_deliveries = ReminderDelivery.index_for(@reminder_setting.key, subjects)
    @reminder_anchors = Reminders::Registry.eligibility_for(@reminder_setting.key)&.anchors_for(subjects) || {}
  end
end
