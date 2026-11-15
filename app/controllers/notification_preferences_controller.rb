class NotificationPreferencesController < ApplicationController
  include NotificationPreferencesData

  before_action :require_authenticated_user!, unless: :token_access_request?
  before_action :set_subject_user
  before_action :require_subject_user!

  def show
    if token_access?
      load_notification_preferences(@subject_user)
    else
      redirect_to preferences_return_path
    end
  end

  def update
    apply_bulk_updates
    redirect_to preferences_return_path, notice: 'Your notification preferences were updated.'
  end

  def opt_out
    category = params[:category].to_s
    channel = params[:channel].presence || 'email'
    unless category.present? && NotificationCategory.opt_out_allowed?(category)
      redirect_to preferences_return_path, alert: 'That notification cannot be turned off.'
      return
    end

    NotificationOptOut.opt_out!(
      @subject_user,
      category: category,
      channel: channel,
      source: token_access? ? 'email_link' : 'self_service'
    )
    redirect_to preferences_return_path(highlight: nil),
                notice: "You will no longer receive #{category_label(category)} by #{channel}."
  end

  private

  def token_access_request?
    params[:token].present?
  end

  def set_subject_user
    if params[:token].present?
      @subject_user = User.find_by_token_for(:notification_preferences, params[:token])
      @token_access = @subject_user.present?
      return
    end

    @subject_user = current_user
  end

  def require_subject_user!
    return if @subject_user.present?

    redirect_to login_path, alert: 'Sign in or use the link from your email to manage notifications.'
  end

  def token_access?
    @token_access == true
  end

  def apply_bulk_updates
    permitted = params.fetch(:preferences, {}).permit!.to_h
    NotificationCategory.each_entry do |entry|
      next unless NotificationCategory.opt_out_allowed?(entry.key)

      channels = permitted[entry.key]
      next if channels.blank?

      NotificationCategory::CHANNELS.each do |channel|
        next unless channels.key?(channel)

        subscribed = ActiveModel::Type::Boolean.new.cast(channels[channel])
        if subscribed
          NotificationOptOut.opt_in!(@subject_user, category: entry.key, channel: channel)
        else
          NotificationOptOut.opt_out!(@subject_user, category: entry.key, channel: channel,
                                                     source: token_access? ? 'email_link' : 'self_service')
        end
      end
    end
  end

  def preferences_return_path(highlight: params[:highlight])
    if token_access?
      token_notification_preferences_path(token: params[:token], highlight: highlight)
    elsif params[:return_to] == 'profile' || !can?(:'dashboard.admin')
      user_path(@subject_user, tab: :notifications, view_as: :self, highlight: highlight)
    else
      root_path(tab: :notifications, highlight: highlight)
    end
  end

  def category_label(key)
    NotificationCategory.find(key)&.name || key.humanize
  end
end
