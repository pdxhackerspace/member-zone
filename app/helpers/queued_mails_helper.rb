module QueuedMailsHelper
  # Pending is amber because it is work waiting on a human, and Failed red because it is mail that
  # did not go out. Approved, Rejected and All are settled outcomes and stay neutral.
  FILTER_CHIPS = [
    { filter: 'pending', label: 'Pending', variant: 'warning' },
    { filter: 'failed', label: 'Failed', variant: 'danger' },
    { filter: 'approved', label: 'Approved' },
    { filter: 'rejected', label: 'Rejected' },
    { filter: 'all', label: 'All' }
  ].freeze

  def queued_mail_chip_active?(filter)
    @filter == filter
  end
end
