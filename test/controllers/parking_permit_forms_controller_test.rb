require 'test_helper'

class ParkingPermitFormsControllerTest < ActionDispatch::IntegrationTest
  setup do
    RateLimiting.reset!
    @member = users(:one)
    @device = WebhookDevice.create!(name: 'Front door kiosk')
  end

  test 'shows the form for a live link without signing in' do
    link = ParkingPermitLink.issue_for_new_permit!(user: @member, webhook_device: @device)

    get parking_permit_form_path(token: link.token)

    assert_response :success
    assert_select 'input[name="parking_notice[location]"]'
    assert_select 'input[name="parking_notice[expires_at]"]'
  end

  test 'an expired or unknown link shows the expired page' do
    link = ParkingPermitLink.issue_for_new_permit!(user: @member, now: 13.hours.ago)

    get parking_permit_form_path(token: link.token)
    assert_response :not_found
    assert_match(/expired/i, response.body)

    get parking_permit_form_path(token: 'made-up')
    assert_response :not_found
  end

  test 'submitting the form creates the permit once' do
    link = ParkingPermitLink.issue_for_new_permit!(user: @member, webhook_device: @device)

    assert_difference 'ParkingNotice.count', 1 do
      patch parking_permit_form_path(token: link.token), params: { parking_notice: permit_params }
    end

    notice = link.reload.parking_notice
    assert_redirected_to parking_permit_form_path(token: link.token)
    assert link.submitted?
    assert_equal [@member], notice.members.to_a
    assert_equal @member, notice.issued_by
    assert_equal @device, notice.webhook_device
    assert_equal 'Woodshop', notice.location

    assert_no_difference 'ParkingNotice.count' do
      patch parking_permit_form_path(token: link.token), params: { parking_notice: permit_params }
    end
  end

  test 'refuses a permit longer than two weeks or missing details' do
    link = ParkingPermitLink.issue_for_new_permit!(user: @member)

    assert_no_difference 'ParkingNotice.count' do
      patch parking_permit_form_path(token: link.token),
            params: { parking_notice: permit_params(expires_at: 15.days.from_now.strftime('%Y-%m-%dT%H:%M')) }
    end
    assert_response :unprocessable_content

    assert_no_difference 'ParkingNotice.count' do
      patch parking_permit_form_path(token: link.token), params: { parking_notice: permit_params(location: '') }
    end
    assert_response :unprocessable_content
  end

  test 'completing a blank permit records the details and keeps the expiry' do
    notice = blank_permit
    expires_at = notice.expires_at
    link = ParkingPermitLink.issue_for_blank_permit!(notice, user: @member)

    patch parking_permit_form_path(token: link.token),
          params: { parking_notice: permit_params(expires_at: 1.day.from_now.strftime('%Y-%m-%dT%H:%M')) }

    notice.reload
    assert_not notice.awaiting_details?
    assert_not_nil notice.details_completed_at
    assert_equal 'Woodshop', notice.location
    assert_in_delta expires_at, notice.expires_at, 1.second
  end

  test 'prints the permit while the link is live' do
    notice = blank_permit
    link = ParkingPermitLink.issue_for_blank_permit!(notice, user: @member)

    get parking_permit_form_pdf_path(token: link.token)

    assert_response :success
    assert_equal 'application/pdf', response.media_type
  end

  test 'a link that has not created its permit yet has nothing to print' do
    link = ParkingPermitLink.issue_for_new_permit!(user: @member)

    get parking_permit_form_pdf_path(token: link.token)

    assert_redirected_to parking_permit_form_path(token: link.token)
  end

  private

  def permit_params(**overrides)
    { description: 'Bookshelf glue-up', location: 'Woodshop', location_detail: 'Bench A',
      expires_at: 3.days.from_now.strftime('%Y-%m-%dT%H:%M') }.merge(overrides)
  end

  def blank_permit
    ParkingNotice.create!(notice_type: 'permit', status: 'active', members: [@member], issued_by: @member,
                          webhook_device: @device, expires_at: 2.weeks.from_now,
                          details_requested_at: Time.current)
  end
end
