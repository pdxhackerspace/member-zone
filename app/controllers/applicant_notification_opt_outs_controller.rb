class ApplicantNotificationOptOutsController < ApplicationController
  before_action :set_verification

  def show
    @category = params[:category].presence || 'application_link'
    @entry = NotificationCategory.find(@category)
    return if @entry && NotificationCategory.opt_out_allowed?(@category)

    redirect_to apply_new_path, alert: 'That notification cannot be turned off.'
    nil
  end

  def create
    category = params[:category].presence || 'application_link'
    channel = params[:channel].presence || 'email'
    unless NotificationCategory.opt_out_allowed?(category)
      redirect_to apply_new_path, alert: 'That notification cannot be turned off.'
      return
    end

    EmailNotificationOptOut.opt_out!(
      @verification.email,
      category: category,
      channel: channel,
      source: 'email_link'
    )
    redirect_to apply_new_path,
                notice: 'You will no longer receive application reminders at this email address.'
  end

  private

  def set_verification
    @verification = ApplicationVerification.find_by(token: params[:token])
    return if @verification

    redirect_to apply_new_path, alert: 'Invalid link.'
  end
end
