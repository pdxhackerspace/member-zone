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

  def resolve_member_permit_member_ids(raw_ids, viewer)
    requested = normalize_member_ids(raw_ids)
    allowed = member_pickable_for_member(viewer).where(id: requested).pluck(:id)
    (allowed + [viewer.id]).uniq
  end
end
