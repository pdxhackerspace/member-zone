module NotificationPreferencesHelper
  # Whether this page may offer its own Notifications tab. The shared preferences form
  # always writes `current_user`, so only a surface rendering for `current_user` can show
  # it; the admin dashboard's member tabs render for `true_user`, who is somebody else
  # while impersonating. Both `dashboard/_navigation` and `users/_self_navigation` are
  # reached from pages that set `@home_user`/`@user` for the member they display.
  def own_notification_preferences?(user = @home_user)
    user.present? && user == current_user
  end

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
