module Journals
  # Renders the `parking_notice` payload that ParkingNotice#record_journal_entry! writes,
  # including a link back to the notice so an admin reading the journal can open it.
  module ParkingNoticeRendering
    BADGE_CLASSES = {
      'permit' => 'text-bg-success-subtle',
      'ticket' => 'text-bg-danger-subtle'
    }.freeze

    def render_parking_notice_change(notice_data)
      content_tag(:div, class: 'small') do
        safe_join(
          [
            parking_notice_headline(notice_data),
            parking_notice_summary(notice_data),
            parking_notice_journal_link(notice_data)
          ].compact,
          tag.br
        )
      end
    end

    def parking_notice_headline(notice_data)
      notice_type = notice_data['notice_type'].to_s
      badge_class = BADGE_CLASSES.fetch(notice_type, 'text-bg-secondary-subtle')
      badge = content_tag(:span, notice_type.capitalize.presence || 'Notice', class: "badge #{badge_class} me-2")
      location = notice_data['location'].presence
      return badge if location.blank?

      safe_join([badge, content_tag(:strong, location)])
    end

    def parking_notice_summary(notice_data)
      parts = []
      parts << "Expires #{notice_data['expires_at']}" if notice_data['expires_at'].present?
      parts << notice_data['description'] if notice_data['description'].present?
      return nil if parts.empty?

      content_tag(:span, parts.join(' · '), class: 'text-muted')
    end

    # The journal is admin-only, so this links to the admin notice page rather than the
    # member-facing permit view.
    def parking_notice_journal_link(notice_data)
      return nil if notice_data['id'].blank?

      label = notice_data['notice_type'] == 'ticket' ? 'View ticket' : 'View permit'
      link_to label, parking_notice_path(notice_data['id']), class: 'link-primary'
    end
  end
end
