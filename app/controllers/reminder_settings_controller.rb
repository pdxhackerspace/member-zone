class ReminderSettingsController < AdminController
  include Pagy::Method

  PER_PAGE = 50

  before_action :set_reminder_setting, only: %i[show update]

  def index
    ReminderSetting.seed_defaults!
    ReminderSetting.sync_catalog_attributes!
    @reminder_settings = ReminderSetting.ordered
    @slack_due_count = Reminders::SlackSignupEligibility.count_due
    @slack_without_slack_count = Reminders::SlackSignupEligibility.total_without_slack
    @slack_source_enabled = MemberSource.enabled?('slack')
    @slack_email_template = EmailTemplate.find_by(key: 'slack_signup_reminder')
    @application_link_due_count = Reminders::ApplicationLinkEligibility.count_due
    @application_link_awaiting_count = Reminders::ApplicationLinkEligibility.total_awaiting
    @application_link_email_template = EmailTemplate.find_by(key: 'application_link_reminder')
    @payment_overdue_due_count = Reminders::PaymentOverdueEligibility.count_due
    @payment_overdue_total_count = Reminders::PaymentOverdueEligibility.total_overdue
    @payment_overdue_email_template = EmailTemplate.find_by(key: 'payment_past_due')
    @orientation_due_count = Reminders::OrientationEligibility.count_due
    @orientation_awaiting_count = Reminders::OrientationEligibility.total_awaiting
    @orientation_email_template = EmailTemplate.find_by(key: 'orientation_reminder')
    @parking_due_count = Reminders::ParkingNoticeEligibility.count_due
    @parking_awaiting_count = Reminders::ParkingNoticeEligibility.total_awaiting
    @parking_expiring_soon_template = EmailTemplate.find_by(key: 'parking_permit_expiring_soon')
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
      load_show_data
      render :show, status: :unprocessable_content
    end
  end

  private

  def set_reminder_setting
    @reminder_setting = ReminderSetting.find_by!(key: params[:key])
  end

  def reminder_setting_params
    params.expect(reminder_setting: %i[enabled allow_opt_out])
  end

  def load_show_data
    @membership_setting = MembershipSetting.instance

    case @reminder_setting.key
    when 'slack_signup'
      @pagy, @due_users = pagy(Reminders::SlackSignupEligibility.due, limit: PER_PAGE)
      @slack_due_count = @pagy.count
      @slack_without_slack_count = Reminders::SlackSignupEligibility.total_without_slack
      @slack_source_enabled = MemberSource.enabled?('slack')
      @slack_email_template = EmailTemplate.find_by(key: 'slack_signup_reminder')
    when 'application_link'
      load_application_link_show_data
    when 'payment_overdue'
      @pagy, @due_users = pagy(Reminders::PaymentOverdueEligibility.due, limit: PER_PAGE)
      @payment_overdue_due_count = @pagy.count
      @payment_overdue_total_count = Reminders::PaymentOverdueEligibility.total_overdue
      @payment_overdue_email_template = EmailTemplate.find_by(key: 'payment_past_due')
    when 'orientation'
      @pagy, @due_users = pagy(Reminders::OrientationEligibility.due, limit: PER_PAGE)
      @orientation_due_count = @pagy.count
      @orientation_awaiting_count = Reminders::OrientationEligibility.total_awaiting
      @orientation_email_template = EmailTemplate.find_by(key: 'orientation_reminder')
      @building_access_topic = TrainingTopic.building_access
    when 'parking_notices'
      load_parking_notices_show_data
    end
  end

  def load_parking_notices_show_data
    @pagy, @due_notices = pagy(Reminders::ParkingNoticeEligibility.due, limit: PER_PAGE)
    @parking_due_count = @pagy.count
    @parking_awaiting_count = Reminders::ParkingNoticeEligibility.total_awaiting
    @parking_expiring_soon_template = EmailTemplate.find_by(key: 'parking_permit_expiring_soon')
  end

  def load_application_link_show_data
    @application_link_awaiting_count = Reminders::ApplicationLinkEligibility.total_awaiting
    @application_link_email_template = EmailTemplate.find_by(key: 'application_link_reminder')

    unless Reminders::ApplicationLinkEligibility.active?
      @pagy, @due_verifications = pagy(ApplicationVerification.none, limit: PER_PAGE)
      @application_link_due_count = 0
      return
    end

    @pagy, @due_verifications = pagy(Reminders::ApplicationLinkEligibility.due, limit: PER_PAGE)
    @application_link_due_count = @pagy.count
  end
end
