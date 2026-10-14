module Api
  module V1
    # A parking permit or ticket. People on it appear as {id, name} — enough to identify them,
    # without the contact details a member lookup would need its own scope for.
    module ParkingNoticeSerializer
      module_function

      def call(notice, photo_path:, events: false)
        body = {
          id: notice.id,
          notice_type: notice.notice_type,
          status: notice.status,
          description: notice.description,
          location: notice.location,
          location_detail: notice.location_detail,
          expires_at: notice.expires_at.iso8601,
          requires_admin_clearance: notice.requires_admin_clearance,
          clearance_requested_at: notice.clearance_requested_at&.iso8601,
          cleared_at: notice.cleared_at&.iso8601,
          created_at: notice.created_at.iso8601,
          updated_at: notice.updated_at.iso8601,
          issued_by: person(notice.issued_by),
          cleared_by: person(notice.cleared_by),
          members: notice.members.map { |member| person(member) },
          photos: notice.photos.map { |photo| photo(photo, photo_path) }
        }
        body[:events] = notice.events.includes(:actor).chronological.map { |event| event(event) } if events
        body
      end

      def person(user)
        user && { id: user.id, name: user.display_name }
      end

      def photo(attachment, photo_path)
        {
          id: attachment.id,
          filename: attachment.filename.to_s,
          content_type: attachment.content_type,
          byte_size: attachment.byte_size,
          download_path: photo_path.call(attachment)
        }
      end

      def event(event)
        {
          event_type: event.event_type,
          note: event.note,
          actor: person(event.actor),
          via_api: event.api_token_id.present?,
          created_at: event.created_at.iso8601
        }
      end
    end
  end
end
