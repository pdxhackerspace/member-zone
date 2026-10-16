module MailLogHelper
  # Colour is reserved for the states an admin has to do something about: red for mail that did not
  # go out, amber for mail that was deliberately held back. Everything else — sent, queued,
  # approved, edited — is the normal course of events and stays neutral.
  STATE_CHIPS = [
    { state: nil, label: 'All' },
    { state: 'sent', label: 'Sent' },
    { state: 'failed', label: 'Failed', variant: 'danger' },
    { state: 'suppressed', label: 'Suppressed', variant: 'warning' },
    { state: 'rejected', label: 'Rejected', variant: 'warning' },
    { state: 'queued', label: 'Queued' },
    { state: 'approved', label: 'Approved' },
    { state: 'edited', label: 'Edited' }
  ].freeze

  # Events an admin has to look at. Everything else is the normal course of a message and reads as
  # a dot and a muted label, so the exceptions stand out down the column.
  EVENT_ALERT_TONES = { 'send_failed' => 'danger', 'suppressed' => 'warning', 'rejected' => 'warning' }.freeze

  EVENT_LABELS = { 'send_failed' => 'Failed', 'created' => 'Queued' }.freeze

  def mail_log_event_label(event)
    EVENT_LABELS.fetch(event, event.humanize)
  end

  def mail_log_event_cell(event)
    label = mail_log_event_label(event)
    tone = EVENT_ALERT_TONES[event]
    return tag.span(label, class: "badge text-bg-#{tone}-subtle") if tone

    dot = event == 'sent' ? 'status-success' : 'status-muted'
    safe_join([tag.span(nil, class: "status-dot #{dot} me-1"), tag.span(label, class: 'text-secondary text-13')])
  end

  # The state chips with their counts, keeping the search as the chip changes. They sit inside the
  # results frame so the search refreshes them, but a click reloads the whole page: the search form
  # outside the frame carries the state along, and only a full load puts the new one there.
  def mail_log_filter_chips(counts)
    STATE_CHIPS.map do |chip|
      { label: chip[:label], variant: chip[:variant], count: counts.fetch(chip[:state] || 'all', 0),
        path: mail_log_path(state: chip[:state], q: @search.presence), active: mail_log_chip_active?(chip[:state]),
        data: { turbo_frame: '_top' } }
    end
  end

  # The All chip carries no state, so it is the selected one when nothing is filtered.
  def mail_log_chip_active?(state)
    state.nil? ? @state.blank? : @state == state
  end

  # What the message itself is doing now, as opposed to the event the row records. A log line saying
  # "Failed" three hours ago means something different depending on whether the message has since
  # gone out, so the queue state is worth showing next to it.
  def mail_log_queue_state(queued_mail)
    return nil unless queued_mail
    return 'Sent' if queued_mail.sent?
    return 'Send failed' if queued_mail.delivery_failed?
    return 'Sending' if queued_mail.delivery_pending?
    return 'Awaiting review' if queued_mail.pending?

    'Rejected' if queued_mail.rejected?
  end
end
