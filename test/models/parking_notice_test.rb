require 'test_helper'

class ParkingNoticeTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
    @other = users(:two)
    @admin = users(:one)
  end

  def build_permit(**attrs)
    notice = ParkingNotice.new(
      notice_type: 'permit',
      issued_by: @admin,
      expires_at: 7.days.from_now,
      description: 'Test project',
      **attrs
    )
    notice.build_members_from_ids!([@user.id])
    notice
  end

  test 'valid permit saves' do
    assert build_permit.valid?
  end

  test 'permit requires at least one member' do
    notice = ParkingNotice.new(
      notice_type: 'permit',
      issued_by: @admin,
      expires_at: 7.days.from_now
    )
    assert_not notice.valid?
    assert_includes notice.errors[:members], 'must include at least one member'
  end

  test 'ticket does not require members' do
    notice = ParkingNotice.new(
      notice_type: 'ticket',
      issued_by: @admin,
      expires_at: 7.days.from_now
    )
    assert notice.valid?
  end

  test 'notice_type must be valid' do
    notice = build_permit
    notice.notice_type = 'warning'
    assert_not notice.valid?
    assert_includes notice.errors[:notice_type], 'is not included in the list'
  end

  test 'status must be valid' do
    notice = build_permit(status: 'invalid')
    assert_not notice.valid?
  end

  test 'expires_at is required' do
    notice = build_permit
    notice.expires_at = nil
    assert_not notice.valid?
    assert_includes notice.errors[:expires_at], "can't be blank"
  end

  test 'permit? returns true for permits' do
    assert parking_notices(:active_permit).permit?
    assert_not parking_notices(:active_permit).ticket?
  end

  test 'ticket? returns true for tickets' do
    assert parking_notices(:expired_ticket).ticket?
    assert_not parking_notices(:expired_ticket).permit?
  end

  test 'active? returns true for active status' do
    assert parking_notices(:active_permit).active?
  end

  test 'expired? returns true for expired status' do
    assert parking_notices(:expired_ticket).expired?
  end

  test 'cleared? returns true for cleared status' do
    assert parking_notices(:cleared_permit).cleared?
  end

  test 'badge_color returns success for permits' do
    assert_equal 'success', parking_notices(:active_permit).badge_color
  end

  test 'badge_color returns danger for tickets' do
    assert_equal 'danger', parking_notices(:expired_ticket).badge_color
  end

  test 'status_badge_color returns correct colors' do
    assert_equal 'primary', parking_notices(:active_permit).status_badge_color
    assert_equal 'danger', parking_notices(:expired_ticket).status_badge_color
    assert_equal 'secondary', parking_notices(:cleared_permit).status_badge_color
  end

  test 'location_display combines location and detail' do
    notice = parking_notices(:active_permit)
    assert_equal 'Woodshop — Near the south wall', notice.location_display
  end

  test 'location_display with only location' do
    notice = ParkingNotice.new(location: 'Lab')
    assert_equal 'Lab', notice.location_display
  end

  test 'clear! sets status and timestamps' do
    notice = parking_notices(:active_permit)
    notice.clear!(@admin)
    assert notice.cleared?
    assert_not_nil notice.cleared_at
    assert_equal @admin, notice.cleared_by
  end

  test 'expire! sets status to expired' do
    notice = parking_notices(:active_permit)
    notice.expire!
    assert notice.expired?
  end

  test 'scopes filter correctly' do
    assert_includes ParkingNotice.permits, parking_notices(:active_permit)
    assert_includes ParkingNotice.tickets, parking_notices(:expired_ticket)
    assert_includes ParkingNotice.active_notices, parking_notices(:active_permit)
    assert_includes ParkingNotice.expired_notices, parking_notices(:expired_ticket)
    assert_includes ParkingNotice.cleared_notices, parking_notices(:cleared_permit)
  end

  test 'not_cleared excludes cleared notices' do
    assert_not_includes ParkingNotice.not_cleared, parking_notices(:cleared_permit)
    assert_includes ParkingNotice.not_cleared, parking_notices(:active_permit)
  end

  test 'needing_expiration finds active past-due notices' do
    active = parking_notices(:active_permit)
    active.update!(expires_at: 1.hour.ago)
    assert_includes ParkingNotice.needing_expiration, active
  end

  test 'for_user scope filters by member' do
    user_notices = ParkingNotice.for_user(@user)
    assert(user_notices.all? { |notice| notice.member?(@user) })
  end

  test 'replace_members! returns newly added members' do
    notice = parking_notices(:active_permit)
    added = notice.replace_members!([@user.id, @other.id])
    assert_equal [@other], added
  end

  test 'record_journal_entry! creates journal for each member' do
    notice = parking_notices(:active_permit)
    notice.replace_members!([@user.id, @other.id])

    assert_difference 'Journal.count', 2 do
      notice.record_journal_entry!('parking_permit_issued', actor: @admin)
    end

    recipients = Journal.order(:id).last(2).map(&:user)
    assert_equal [@user, @other].sort_by(&:id), recipients.sort_by(&:id)
    assert_equal @admin, Journal.order(:id).last.actor_user
    assert Journal.order(:id).last.highlight?
  end

  test 'record_journal_entry! does nothing without members' do
    notice = parking_notices(:anonymous_ticket)
    assert_no_difference 'Journal.count' do
      notice.record_journal_entry!('parking_ticket_issued')
    end
  end

  test 'clearable_by? lets a member on the notice clear their active notice' do
    assert parking_notices(:active_permit).clearable_by?(@user)
  end

  test 'clearable_by? blocks a non-member who is not an admin' do
    other = users(:two)
    assert_not parking_notices(:active_permit).clearable_by?(other)
  end

  test 'clearable_by? lets a co-member clear the notice' do
    notice = parking_notices(:active_permit)
    notice.replace_members!([@user.id, @other.id])
    assert notice.clearable_by?(@other)
  end

  test 'clearable_by? blocks the owner when admin clearance is required' do
    notice = parking_notices(:active_permit)
    notice.update!(requires_admin_clearance: true)
    assert_not notice.clearable_by?(@user)
  end

  test 'clearable_by? always lets an admin clear, even when admin clearance is required' do
    admin = users(:two)
    admin.update!(is_admin: true)
    notice = parking_notices(:active_permit)
    notice.update!(requires_admin_clearance: true)
    assert notice.clearable_by?(admin)
  end

  test 'clearable_by? blocks clearing an already-cleared notice' do
    assert_not parking_notices(:cleared_permit).clearable_by?(@user)
  end

  test 'clearable_by? lets a member clear their own expired ticket' do
    expired = parking_notices(:expired_ticket)
    assert expired.clearable_by?(expired.members.first)
  end

  test 'clearable_by? blocks the member clearing an expired ticket when admin clearance is required' do
    expired = parking_notices(:expired_ticket)
    expired.update!(requires_admin_clearance: true)
    assert_not expired.clearable_by?(expired.members.first)
  end

  test 'creating a notice logs an opened event' do
    notice = nil
    assert_difference 'ParkingNoticeEvent.count', 1 do
      notice = build_permit
      notice.save!
    end
    event = notice.events.last
    assert_equal 'opened', event.event_type
    assert_equal @admin, event.actor
  end

  test 'clear! logs a cleared event' do
    notice = parking_notices(:active_permit)
    assert_difference 'ParkingNoticeEvent.count', 1 do
      notice.clear!(@admin)
    end
    assert_equal 'cleared', notice.events.last.event_type
  end

  test 'expire! logs an expired event' do
    notice = parking_notices(:active_permit)
    assert_difference 'ParkingNoticeEvent.count', 1 do
      notice.expire!
    end
    assert_equal 'expired', notice.events.last.event_type
  end

  test 'changing the expiration logs a renewed event' do
    notice = parking_notices(:active_permit)
    assert_difference 'ParkingNoticeEvent.count', 1 do
      notice.update!(expires_at: 30.days.from_now)
    end
    assert_equal 'renewed', notice.events.last.event_type
  end

  test 'updating without changing expiration does not log a renewed event' do
    notice = parking_notices(:active_permit)
    assert_no_difference 'ParkingNoticeEvent.count' do
      notice.update!(description: 'Tweaked description')
    end
  end

  test 'log_event! records a note with its text' do
    notice = parking_notices(:active_permit)
    notice.log_event!('note', actor: @admin, note: 'Spoke with the member')
    event = notice.events.last
    assert_equal 'note', event.event_type
    assert_equal 'Spoke with the member', event.note
    assert_equal @admin, event.actor
  end

  test 'request_clearance! records the request and logs an event' do
    notice = parking_notices(:active_permit)
    notice.update!(requires_admin_clearance: true)

    assert_difference 'ParkingNoticeEvent.count', 1 do
      notice.request_clearance!(@user)
    end

    assert notice.clearance_requested?
    assert_equal @user, notice.clearance_requested_by
    assert_equal 'clearance_requested', notice.events.last.event_type
  end

  test 'clearance_requested? is false once the notice is cleared' do
    notice = parking_notices(:active_permit)
    notice.update!(requires_admin_clearance: true)
    notice.request_clearance!(@user)
    notice.clear!(@admin)
    assert_not notice.clearance_requested?
  end
end
