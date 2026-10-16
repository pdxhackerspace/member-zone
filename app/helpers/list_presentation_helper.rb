# How one row reads in an index table: the amount, the status and the timestamp. Shared by every
# list page so that a date, a dollar figure and a status look the same wherever they turn up.
module ListPresentationHelper
  # PayPal reports a one-letter transaction status; everything else spells its own out.
  SUCCESS_STATUSES = %w[s success completed complete paid].freeze

  # A filter link for a list whose filters stack across several axes: it keeps the other axes
  # as they are, drops the page number, and clicking the value already showing clears that one
  # axis rather than the lot.
  def list_filter_path(path_helper, key, value, extra = {})
    carried = request.query_parameters.except('page').merge(extra.stringify_keys)
    key = key.to_s
    carried = if carried[key].to_s == value.to_s && value.present?
                carried.except(key)
              else
                carried.merge(key => value)
              end
    public_send(path_helper, carried.compact_blank)
  end

  # Money in a list cell. The dollar figure is the bright part; the symbol and the cents are
  # dimmed so a column of identical dues payments stops shouting and an odd amount stands out.
  def list_money_tag(amount, currency = nil)
    return tag.span('—', class: 'text-secondary') if amount.blank?

    value = amount.to_d
    whole = value.truncate
    cents = ((value - whole).abs * 100).round
    code = currency.to_s.strip.presence
    parts = [tag.span('$', class: 'currency'), number_with_delimiter(whole),
             tag.span(format('.%02d', cents), class: 'cents')]
    parts << tag.span(" #{code}", class: 'cents') if code && code.casecmp('USD') != 0
    tag.span(safe_join(parts), class: 'money')
  end

  # Tones an exceptional status can carry: a failed charge is a problem, a deactivated account
  # is merely not the common case.
  STATUS_TONES = { 'danger' => 'danger', 'warning' => 'warning', 'muted' => 'secondary' }.freeze

  # A dot for the status nearly every row shares, a labelled subtle badge for the exceptions.
  def list_status_cell(status, tone: 'danger', success: nil)
    label = status.to_s.strip.presence || 'Unknown'
    ok = success.nil? ? list_status_success?(label) : success
    return tag.span(nil, class: 'status-dot status-success', title: label) if ok

    badge_tone = STATUS_TONES.fetch(tone, 'danger')
    safe_join([tag.span(nil, class: "status-dot status-#{tone} me-1", title: label),
               tag.span(label, class: "badge text-bg-#{badge_tone}-subtle")])
  end

  def list_status_success?(status)
    SUCCESS_STATUSES.include?(status.to_s.strip.downcase)
  end

  # List timestamps follow the house rule: today shows a time, the past week shows how long
  # ago, anything older shows a date. The exact moment stays available on hover.
  def list_time_tag(time, empty: 'n/a')
    return tag.span(empty, class: 'text-secondary') if time.blank?

    title = time.acts_like?(:time) ? l(time, format: :long) : l(time.to_date, format: :long)
    tag.span(list_time_label(time), class: 'text-secondary', title: title)
  end

  # A cash payment carries a date and nothing finer, so it says Today where a processor
  # timestamp would say the hour.
  def list_time_label(time)
    date = time.to_date
    today = Time.zone.today
    return time.acts_like?(:time) ? time.in_time_zone.strftime('%-l:%M %p') : 'Today' if date == today
    return 'Yesterday' if date == today - 1
    return "#{(today - date).to_i} days ago" if date > today - 7 && date < today
    return date.strftime('%b %-d') if date.year == today.year

    date.strftime('%b %-d, %Y')
  end
end
