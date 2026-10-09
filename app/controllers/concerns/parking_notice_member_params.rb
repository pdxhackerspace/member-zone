module ParkingNoticeMemberParams
  extend ActiveSupport::Concern

  private

  def member_pickable_for_member(viewer)
    User.access_granting
        .non_service_accounts
        .profile_visible_to(viewer)
        .where.not(id: viewer.id)
  end

  def normalize_member_ids(raw_ids)
    Array(raw_ids).filter_map { |raw| raw.presence&.to_i }.uniq
  end

  def resolve_admin_member_ids(raw_ids)
    normalize_member_ids(raw_ids)
  end

  # Newly added members must be ones the viewer could pick. Members already on the notice
  # stay unless the viewer may remove them and left them out, so a co-member cannot drop the
  # issuer and nobody is dropped just because the viewer cannot see their profile.
  def resolve_member_permit_member_ids(raw_ids, viewer, notice = nil)
    requested = normalize_member_ids(raw_ids)
    existing = notice&.persisted? ? notice.members.ids : []
    kept = notice.nil? || notice.members_removable_by?(viewer) ? existing & requested : existing
    added = member_pickable_for_member(viewer).where(id: requested - existing).pluck(:id)
    (kept + added + [viewer.id]).uniq
  end
end
