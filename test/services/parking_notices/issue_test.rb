require 'test_helper'

module ParkingNotices
  class IssueTest < ActiveSupport::TestCase
    setup do
      @staff = users(:one)
      @member = users(:two)
      @other = users(:three)
    end

    test 'staff issue a ticket to the members they name' do
      result = Issue.call(actor: @staff, attributes: ticket_attributes, member_ids: [@member.id.to_s, ''])

      assert result.success?
      notice = result.notice
      assert notice.persisted?
      assert notice.ticket?
      assert_equal @staff, notice.issued_by
      assert_equal [@member], notice.members.to_a
    end

    test 'staff may issue a ticket nobody is named on' do
      result = Issue.call(actor: @staff, attributes: ticket_attributes, member_ids: nil)

      assert result.success?
      assert_empty result.notice.members
    end

    test 'staff issue journals the notice for each member' do
      assert_difference -> { Journal.where(action: 'parking_ticket_issued', user: @member).count }, 1 do
        Issue.call(actor: @staff, attributes: ticket_attributes, member_ids: [@member.id])
      end
    end

    test 'the opened event names the actor' do
      notice = Issue.call(actor: @staff, attributes: ticket_attributes, member_ids: [@member.id]).notice

      assert_equal @staff, notice.events.find_by(event_type: 'opened').actor
    end

    test 'a permit with no members is invalid' do
      result = nil
      assert_no_difference 'ParkingNotice.count' do
        result = Issue.call(actor: @staff, attributes: permit_attributes, member_ids: [])
      end

      assert_equal :invalid, result.error
      assert_not result.success?
      assert result.notice.errors[:members].any?
    end

    test 'self service always issues an active permit with the issuer on it' do
      attributes = permit_attributes.merge(notice_type: 'ticket', status: 'cleared')
      result = Issue.call(actor: @member, attributes: attributes, member_ids: [], self_service: true)

      assert result.success?
      assert result.notice.permit?
      assert result.notice.active?
      assert_equal [@member], result.notice.members.to_a
    end

    test 'self service journals the permit' do
      assert_difference -> { Journal.where(action: 'parking_permit_issued', user: @member).count }, 1 do
        Issue.call(actor: @member, attributes: permit_attributes, member_ids: [], self_service: true)
      end
    end

    test 'self service only adds members the issuer could pick' do
      @other.update_columns(profile_visibility: 'private')
      result = Issue.call(actor: @member, attributes: permit_attributes, member_ids: [@other.id], self_service: true)

      assert result.success?
      assert_equal [@member], result.notice.members.to_a
    end

    test 'self service refuses a permit longer than the self-service maximum' do
      attributes = permit_attributes.merge(expires_at: 15.days.from_now)
      result = nil
      assert_no_difference 'ParkingNotice.count' do
        result = Issue.call(actor: @member, attributes: attributes, member_ids: [], self_service: true)
      end

      assert_equal :invalid, result.error
      assert_includes result.notice.errors[:expires_at], 'must be within 2 weeks'
    end

    test 'staff are not held to the self-service maximum' do
      attributes = permit_attributes.merge(expires_at: 60.days.from_now)

      assert Issue.call(actor: @staff, attributes: attributes, member_ids: [@member.id]).success?
    end

    private

    def ticket_attributes
      { notice_type: 'ticket', description: 'Left on bench', location: 'Main Area', expires_at: 3.days.from_now }
    end

    def permit_attributes
      { notice_type: 'permit', description: 'Project', location: 'Woodshop', expires_at: 3.days.from_now }
    end
  end
end
