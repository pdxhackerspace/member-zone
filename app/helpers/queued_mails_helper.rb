module QueuedMailsHelper
  # Pending is amber because it is work waiting on a human, and Failed red because it is mail that
  # did not go out. Approved, Rejected and All are settled outcomes and stay neutral.
  FILTER_TILES = [
    { filter: 'pending', label: 'Pending', variant: 'warning' },
    { filter: 'failed', label: 'Failed', variant: 'danger' },
    { filter: 'approved', label: 'Approved' },
    { filter: 'rejected', label: 'Rejected' },
    { filter: 'all', label: 'All' }
  ].freeze

  # The queue's buckets as a tile row. A tile only takes its colour while it has something in it:
  # an empty Failed bucket is good news and should not look like an alarm.
  def queued_mail_filter_tiles(counts)
    FILTER_TILES.map do |tile|
      count = counts.fetch(tile[:filter], 0)
      { label: tile[:label], count: count, path: queued_mails_path(filter: tile[:filter]),
        active: @filter == tile[:filter], variant: (tile[:variant] if count.positive?) }
    end
  end

  # Sent is what nearly every settled row says, so it gets the dot; everything else is the
  # exception and carries a labelled badge.
  def queued_mail_status_cell(queued_mail)
    label, tone = queued_mail_status(queued_mail)
    return tag.span(nil, class: 'status-dot status-success', title: queued_mail_sent_title(queued_mail)) if tone.nil?

    tag.span(label, class: "badge text-bg-#{tone}-subtle")
  end

  # The label and badge tone for a message's place in the queue; a nil tone means it went out.
  def queued_mail_status(queued_mail)
    return ['Send failed', 'danger'] if queued_mail.delivery_failed?
    return %w[Sending info] if queued_mail.delivery_pending?
    return ['Sent', nil] if queued_mail.sent?
    return ['Pending review', 'warning'] if queued_mail.pending?
    return %w[Approved success] if queued_mail.approved?

    %w[Rejected secondary]
  end

  private

  def queued_mail_sent_title(queued_mail)
    queued_mail.sent_at ? "Sent #{l(queued_mail.sent_at, format: :long)}" : 'Sent'
  end
end
