module UsersHelper
  # The legacy membership_status column, which is now a projection of membership_state.
  # Prefer membership_state_label; this is here for the views still reading the old column.
  def membership_status_label(status)
    status.to_s.humanize
  end

  # Build a URL that toggles one filter while preserving all other active filters.
  # If the filter is already active with the same value, clicking removes it.
  # Passing nil as filter_value always removes that filter key.
  def stacking_filter_path(filter_key, filter_value)
    new_params = @filter_params.dup
    if filter_value.nil? || new_params[filter_key].to_s == filter_value.to_s
      new_params.delete(filter_key)
    else
      new_params[filter_key] = filter_value
    end
    users_path(new_params)
  end

  def member_admin_tenure(user)
    if user.membership_start_date.present? && user.membership_ended_date.present?
      "Member #{user.membership_start_date.strftime('%b %Y')} - #{user.membership_ended_date.strftime('%b %Y')}"
    elsif user.membership_start_date.present?
      "Member since #{user.membership_start_date.strftime('%b %Y')}"
    elsif user.membership_ended_date.present?
      "Membership ended #{user.membership_ended_date.strftime('%b %Y')}"
    else
      "Member record created #{user.created_at.strftime('%b %Y')}"
    end
  end

  def member_preview_label(view_level)
    {
      admin: 'Admin',
      self: 'the member',
      members: 'other members',
      public: 'public visitors'
    }[view_level.to_sym] || view_level.to_s.humanize
  end

  def admin_profile_time(value, empty: 'Never')
    return content_tag(:span, empty, class: 'profile-field-value empty') if value.blank?

    content_tag(:span, class: 'profile-field-value', title: l(value, format: :long)) do
      if value.to_date == Date.current
        value.strftime('%-l:%M %p')
      elsif value.to_date == Date.yesterday
        'Yesterday'
      elsif value.to_date > 7.days.ago.to_date
        "#{time_ago_in_words(value)} ago"
      elsif value.year == Date.current.year
        value.strftime('%b %-d')
      else
        value.strftime('%b %-d, %Y')
      end
    end
  end

  # Lowercase haystack for client-side live-filter (name, email, username, Authentik ID).
  def user_live_search_text(user)
    [user.display_name, user.email, user.username, user.authentik_id].compact.join(' ').downcase
  end
end
