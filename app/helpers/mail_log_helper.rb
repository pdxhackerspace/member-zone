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

  EVENT_BADGE_CLASSES = {
    'send_failed' => 'text-bg-danger-subtle',
    'suppressed' => 'text-bg-warning-subtle',
    'rejected' => 'text-bg-warning-subtle',
    'sent' => 'text-bg-success-subtle',
    'approved' => 'text-bg-success-subtle',
    'edited' => 'text-bg-info-subtle',
    'regenerated' => 'text-bg-info-subtle'
  }.freeze

  EVENT_LABELS = { 'send_failed' => 'Failed', 'created' => 'Queued' }.freeze

  def mail_log_event_badge_class(event)
    EVENT_BADGE_CLASSES.fetch(event, 'text-bg-secondary-subtle')
  end

  def mail_log_event_label(event)
    EVENT_LABELS.fetch(event, event.humanize)
  end

  def mail_log_chip_class(chip, count)
    active = chip[:state].nil? ? @state.blank? : @state == chip[:state]
    ['filter-chip', 'text-decoration-none', chip[:variant], ('active' if active),
     ('muted' if count.zero?)].compact.join(' ')
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
