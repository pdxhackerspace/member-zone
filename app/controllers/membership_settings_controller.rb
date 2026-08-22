class MembershipSettingsController < AuthenticatedController
  before_action -> { require_privilege!(:'membership_settings.manage') }
  def show
    @membership_setting = MembershipSetting.instance
  end

  def edit
    @membership_setting = MembershipSetting.instance
  end

  def update
    @membership_setting = MembershipSetting.instance

    if @membership_setting.update(membership_setting_params)
      redirect_to membership_settings_path, notice: 'Membership settings updated successfully.'
    else
      render :edit, status: :unprocessable_content
    end
  end

  private

  def membership_setting_params
    params.expect(membership_setting: %i[payment_grace_period_days reactivation_grace_period_months
                                         invitation_expiry_hours login_link_expiry_hours
                                         admin_login_link_expiry_minutes
                                         application_verification_expiry_hours
                                         manual_payment_due_soon_days
                                         application_review_time_cap_days
                                         slack_signup_reminder_initial_delay_days
                                         slack_signup_reminder_repeat_delay_days
                                         slack_signup_reminder_max_account_age_months
                                         application_link_reminder_delay_days
                                         application_link_reminder_max_count
                                         new_member_grace_period_days
                                         new_member_expiry_days
                                         overdue_grace_period_days
                                         payment_overdue_reminder_repeat_days
                                         orientation_reminder_repeat_days
                                         parking_notice_reminder_days_before_expiration
                                         parking_notice_expired_reminder_repeat_days
                                         parking_notice_final_reminder_days_after_expiration
                                         planless_payment_window_days
                                         payment_currency_buffer_days
                                         building_access_training_topic_id])
  end
end
