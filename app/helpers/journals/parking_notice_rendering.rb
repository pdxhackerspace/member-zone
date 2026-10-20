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
            parking_notice_note(notice_data),
            parking_notice_summary(notice_data),
            parking_journal_api_token(notice_data),
            parking_notice_journal_link(notice_data)
          ].compact,
          tag.br
        )
      end
    end

    # A device emailed the member a permit form. The permit only exists once they submit it, so
    # the link to it is looked up rather than stored.
    def render_parking_permit_link_change(link_data)
      notice_id = ParkingPermitLink.where(id: link_data['id']).pick(:parking_notice_id) if link_data['id'].present?
      content_tag(:div, class: 'small') do
        safe_join(
          [
            safe_join([content_tag(:span, 'Permit', class: 'badge text-bg-success-subtle me-2'),
                       content_tag(:strong, 'Permit form emailed')]),
            parking_permit_link_status(link_data, notice_id),
            parking_journal_api_token(link_data),
            (link_to('View permit', parking_notice_path(notice_id), class: 'link-primary') if notice_id)
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

    def parking_notice_note(notice_data)
      return nil if notice_data['note'].blank?

      content_tag(:span, notice_data['note'])
    end

    def parking_notice_summary(notice_data)
      parts = []
      parts << "Expires #{notice_data['expires_at']}" if notice_data['expires_at'].present?
      parts << notice_data['description'] if notice_data['description'].present?
      return nil if parts.empty?

      content_tag(:span, parts.join(' · '), class: 'text-muted')
    end

    def parking_journal_api_token(data)
      name = data.dig('api_token', 'name')
      return nil if name.blank?

      content_tag(:span, class: 'text-muted') do
        safe_join([content_tag(:i, nil, class: 'bi bi-plug me-1'), "Via API token #{name}"])
      end
    end

    # The journal is admin-only, so this links to the admin notice page rather than the
    # member-facing permit view.
    def parking_notice_journal_link(notice_data)
      return nil if notice_data['id'].blank?

      label = notice_data['notice_type'] == 'ticket' ? 'View ticket' : 'View permit'
      link_to label, parking_notice_path(notice_data['id']), class: 'link-primary'
    end

    private

    def parking_permit_link_status(link_data, notice_id)
      return content_tag(:span, 'Submitted', class: 'text-muted') if notice_id
      return nil if link_data['expires_at'].blank?

      expires_at = Time.zone.parse(link_data['expires_at'])
      content_tag(:span, "Link expires #{l(expires_at, format: :long)}", class: 'text-muted')
    end
  end
end
