module ApiTokensHelper
  EXPIRY_WARNING = 30.days

  # Active tokens are the common case and get a quiet dot; anything that needs undoing gets a
  # labelled badge.
  def api_token_state(token)
    case token.state
    when 'active' then tag.span(class: 'status-dot status-success', title: 'Active')
    when 'suspended' then tag.span('Suspended', class: 'badge text-bg-warning-subtle')
    when 'expired' then tag.span('Expired', class: 'badge text-bg-secondary-subtle')
    else tag.span('Revoked', class: 'badge text-bg-danger-subtle')
    end
  end

  # Expiry dates are in the future, so they read forward: "in 5 days", "Mar 4", "Mar 4, 2027".
  # Amber once the expiry is close enough that someone should act.
  def api_token_expiry(token)
    value = token.expires_at
    text = if value.future? && value < 7.days.from_now
             "in #{distance_of_time_in_words(Time.current, value)}"
           elsif value.year == Date.current.year
             value.strftime('%b %-d')
           else
             value.strftime('%b %-d, %Y')
           end
    warn = !token.revoked? && value < EXPIRY_WARNING.from_now
    tag.span(text, class: ('text-warning' if warn), title: l(value, format: :long))
  end

  def api_token_last_used(token)
    return tag.span('Never', class: 'text-secondary') if token.last_used_at.blank?

    tag.span("#{time_ago_in_words(token.last_used_at)} ago", title: l(token.last_used_at, format: :long))
  end

  def api_token_scope_label(key)
    Privilege.catalog_entry(key)&.dig(:label) || key
  end
end
