require 'test_helper'

class ParkingPermitsLinkSubmissionTest < ActiveSupport::TestCase
  setup do
    @member = users(:one)
    @attributes = { description: 'Bookshelf glue-up', location: 'Woodshop', expires_at: 3.days.from_now }
  end

  # Two concurrent submits each load the link before either writes; the second one's copy still
  # says the link is unused when it gets to the service.
  test 'a stale copy of a create link cannot make a second permit' do
    link = ParkingPermitLink.issue_for_new_permit!(user: @member)
    first = ParkingPermitLink.find(link.id)
    second = ParkingPermitLink.find(link.id)

    assert_difference 'ParkingNotice.count', 1 do
      assert ParkingPermits::LinkSubmission.call(first, @attributes)
      assert_nil ParkingPermits::LinkSubmission.call(second, @attributes)
    end
  end
end
