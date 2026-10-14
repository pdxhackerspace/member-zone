require 'test_helper'

module ParkingNotices
  class UpdateTest < ActiveSupport::TestCase
    setup do
      @staff = users(:one)
      @member = users(:two)
      @other = users(:three)
    end

    test 'nil member_ids leaves the members alone' do
      notice = parking_notices(:active_permit)
      result = Update.call(notice: notice, actor: @staff, attributes: { description: 'Changed' })

      assert result.success?
      assert_equal 'Changed', notice.reload.description
      assert_equal [users(:one)], notice.members.to_a
    end

    test 'staff replace the member list and newly added members are notified' do
      notice = parking_notices(:active_permit)
      result = nil

      assert_difference 'QueuedMail.count', 1 do
        result = Update.call(notice: notice, actor: @staff, attributes: {}, member_ids: [@member.id])
      end

      assert result.success?
      assert_equal [@member], result.newly_added
      assert_equal [@member], notice.reload.members.to_a
    end

    test 'removing every member from a permit is invalid and rolls back' do
      notice = parking_notices(:active_permit)
      result = Update.call(notice: notice, actor: @staff, attributes: { description: 'Changed' }, member_ids: [])

      assert_equal :invalid, result.error
      assert_equal [users(:one)], notice.reload.members.to_a
      assert_equal 'Large woodworking project on table', notice.description
    end

    test 'an invalid attribute is reported' do
      notice = parking_notices(:active_permit)
      result = Update.call(notice: notice, actor: @staff, attributes: { notice_type: 'bogus' })

      assert_equal :invalid, result.error
      assert notice.errors[:notice_type].any?
    end

    test 'changing the expiry logs a renewal by the actor' do
      notice = parking_notices(:active_permit)
      Update.call(notice: notice, actor: @staff, attributes: { expires_at: 9.days.from_now })

      assert_equal @staff, notice.events.find_by(event_type: 'renewed').actor
    end

    test 'self service refuses pushing the expiry past the maximum' do
      notice = own_permit
      result = Update.call(notice: notice, actor: @member, attributes: { expires_at: 20.days.from_now },
                           self_service: true)

      assert_equal :invalid, result.error
      assert_includes notice.errors[:expires_at], 'must be within 2 weeks'
    end

    test 'self service may edit other fields on a permit already past the maximum' do
      notice = own_permit
      notice.update_columns(expires_at: 30.days.from_now)
      result = Update.call(notice: notice, actor: @member, attributes: { description: 'Still here' },
                           self_service: true)

      assert result.success?
    end

    test 'a co-member cannot drop the issuer' do
      notice = own_permit
      notice.replace_members!([@member.id, @other.id])
      result = Update.call(notice: notice, actor: @other, attributes: {}, member_ids: [@other.id],
                           self_service: true)

      assert result.success?
      assert_equal [@member.id, @other.id].sort, notice.reload.members.ids.sort
    end

    test 'the issuer may drop a co-member' do
      notice = own_permit
      notice.replace_members!([@member.id, @other.id])
      result = Update.call(notice: notice, actor: @member, attributes: {}, member_ids: [], self_service: true)

      assert result.success?
      assert_equal [@member], notice.reload.members.to_a
    end

    private

    def own_permit
      Issue.call(
        actor: @member, attributes: { description: 'Mine', location: 'Woodshop', expires_at: 3.days.from_now },
        member_ids: [], self_service: true
      ).notice
    end
  end
end
