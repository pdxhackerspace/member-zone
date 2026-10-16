# How a payment reads in a list: the amount, the status and the timestamp of one row, shared by
# the PayPal, Recharge, Ko-fi and cash indexes so the four pages stay the same page.
module PaymentListHelper
  # PayPal reports a one-letter transaction status; the other processors spell theirs out.
  PAYMENT_SUCCESS_STATUSES = %w[s success completed complete paid].freeze

  # Money in a list cell. The dollar figure is the bright part; the symbol and the cents are
  # dimmed so a column of identical dues payments stops shouting and an odd amount stands out.
  def payment_money_tag(amount, currency = nil)
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

  # A dot for the status nearly every row shares, a labelled subtle badge for the exceptions.
  def payment_status_cell(status)
    label = status.to_s.strip.presence || 'Unknown'
    return tag.span(nil, class: 'status-dot status-success', title: label) if payment_succeeded?(label)

    safe_join([tag.span(nil, class: 'status-dot status-danger me-1', title: label),
               tag.span(label, class: 'badge text-bg-danger-subtle')])
  end

  def payment_succeeded?(status)
    PAYMENT_SUCCESS_STATUSES.include?(status.to_s.strip.downcase)
  end

  # List timestamps follow the house rule: today shows a time, the past week shows how long
  # ago, anything older shows a date. The exact moment stays available on hover.
  def payment_time_tag(time, empty: 'n/a')
    return tag.span(empty, class: 'text-secondary') if time.blank?

    title = time.acts_like?(:time) ? l(time, format: :long) : l(time.to_date, format: :long)
    tag.span(payment_time_label(time), class: 'text-secondary', title: title)
  end

  # A cash payment carries a date and nothing finer, so it says Today where a processor
  # timestamp would say the hour.
  def payment_time_label(time)
    date = time.to_date
    today = Time.zone.today
    return time.acts_like?(:time) ? time.in_time_zone.strftime('%-l:%M %p') : 'Today' if date == today
    return 'Yesterday' if date == today - 1
    return "#{(today - date).to_i} days ago" if date > today - 7 && date < today
    return date.strftime('%b %-d') if date.year == today.year

    date.strftime('%b %-d, %Y')
  end
end
