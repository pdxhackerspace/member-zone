module ParkingNotices
  # Who may be put on a notice. Staff may name anyone; members are limited to people they could
  # pick in the member picker, and may not drop people they are not allowed to remove.
  module MemberResolution
    module_function

    # The members a member may add to a permit of their own.
    def pickable_for(viewer)
      User.access_granting
          .non_service_accounts
          .profile_visible_to(viewer)
          .where.not(id: viewer.id)
    end

    def normalize(raw_ids)
      Array(raw_ids).filter_map { |raw| raw.presence&.to_i }.uniq
    end

    # Newly added members must be ones the viewer could pick. Members already on the notice
    # stay unless the viewer may remove them and left them out, so a co-member cannot drop the
    # issuer and nobody is dropped just because the viewer cannot see their profile.
    def for_self_service(raw_ids, viewer, notice = nil)
      requested = normalize(raw_ids)
      existing = notice&.persisted? ? notice.members.ids : []
      kept = notice.nil? || notice.members_removable_by?(viewer) ? existing & requested : existing
      added = pickable_for(viewer).where(id: requested - existing).pluck(:id)
      (kept + added + [viewer.id]).uniq
    end
  end
end
