module NotificationPreferencesData
  private

  def load_notification_preferences(user)
    @subject_user = user
    @grouped_categories = NotificationCategory.grouped_for_member(@subject_user)
    @opt_out_lookup = NotificationOptOut.where(user: @subject_user).each_with_object({}) do |row, hash|
      hash[row.category] ||= {}
      hash[row.category][row.channel] = true
    end
    @highlight_category = params[:highlight].presence
    @highlight_entry = NotificationCategory.find(@highlight_category) if @highlight_category.present?
  end
end
