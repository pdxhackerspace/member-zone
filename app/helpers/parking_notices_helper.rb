module ParkingNoticesHelper
  def parking_notice_member_search_text(user)
    [user.parking_member_label, user.display_name, user.email, user.username].compact.join(' ').downcase
  end

  def parking_notice_members_display(notice, max: 3, link: false)
    members = notice.members.to_a
    return '—' if members.empty?

    shown = members.first(max)
    labels = shown.map do |member|
      if link
        link_to(member.parking_member_label, user_path(member), class: 'text-decoration-none')
      else
        member.parking_member_label
      end
    end
    remainder = members.size - shown.size
    labels << "+#{remainder}" if remainder.positive?
    safe_join(labels, ', ')
  end
end
