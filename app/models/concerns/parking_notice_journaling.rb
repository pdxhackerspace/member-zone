# Journal entries on each member of a parking notice. Every entry carries the notice's id so the
# journal can link back to the permit or ticket, and — when the change came in through the API —
# the token that made it, since the actor alone would read as though the holder did it by hand.
module ParkingNoticeJournaling
  extend ActiveSupport::Concern

  # Notice fields whose changes are worth naming in an "updated" entry.
  JOURNALED_FIELDS = %w[notice_type description location location_detail expires_at requires_admin_clearance
                        status].freeze

  def record_journal_entry!(action_name, actor: nil, note: nil)
    payload = journal_payload(note)
    members.find_each do |member|
      Journal.create!(
        user: member,
        actor_user: actor,
        action: action_name,
        changes_json: payload,
        changed_at: Time.current
      )
    end
  end

  # The fields the last save changed, in words, for the note on an "updated" entry.
  def journaled_field_changes
    (saved_changes.keys & JOURNALED_FIELDS).map { |field| self.class.human_attribute_name(field).downcase }
  end

  private

  def journal_payload(note)
    {
      'parking_notice' => {
        'id' => id,
        'notice_type' => notice_type,
        'location' => location_display,
        'expires_at' => expires_at.strftime('%B %d, %Y'),
        'description' => description.to_s.truncate(100),
        'note' => note.presence&.truncate(200),
        'api_token' => journal_api_token
      }.compact
    }
  end

  def journal_api_token
    token = Current.api_token
    token && { 'id' => token.id, 'name' => token.name }
  end
end
