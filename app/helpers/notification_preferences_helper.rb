module NotificationPreferencesHelper
  def opted_out?(lookup, category_key, channel)
    lookup.dig(category_key, channel) == true
  end

  def notification_row_class(entry)
    NotificationCategory.opt_out_allowed?(entry.key) ? '' : 'text-secondary'
  end

  def notification_channel_disabled?(entry)
    !NotificationCategory.opt_out_allowed?(entry.key)
  end

  def notification_summary_label(user)
    count = NotificationOptOut.where(user: user).count { |row| NotificationCategory.opt_out_allowed?(row.category) }
    if count.zero?
      'Receiving all optional notices'
    else
      "#{count} turned off"
    end
  end
end
