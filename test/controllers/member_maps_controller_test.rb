require 'test_helper'

class MemberMapsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true
    sign_in_as_admin
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  test 'should get show' do
    get member_map_url

    assert_response :success
    assert_select '#member-map[data-markers]'
    assert_select 'link[href*="leaflet.css"]', false
    assert_select '.status-panel', text: /Default view/, count: 0
    assert_select 'a[href=?]', edit_map_default_settings_path, text: /Map settings/
  end

  test 'should show mapped members' do
    users(:one).update_columns(
      active: true,
      mailing_latitude: 45.582,
      mailing_longitude: -122.682,
      mailing_geocoded_at: Time.current
    )

    get member_map_url

    assert_response :success
    assert_includes response.body, 'Example User One'
  end

  test 'excludes inactive mapped members by default' do
    users(:one).update_columns(
      active: false,
      membership_state: 'current_member',
      mailing_latitude: 45.582,
      mailing_longitude: -122.682,
      mailing_geocoded_at: Time.current
    )

    get member_map_url

    assert_response :success
    assert_not_includes response.body, 'Example User One'
    markers = JSON.parse(css_select('#member-map').first['data-markers'])
    assert_not_includes markers.map { |marker| marker.fetch('name') }, 'Example User One'
    assert_select 'input[name=?][value=?]', 'include_inactive', '1'
  end

  test 'includes inactive mapped members when requested' do
    users(:one).update_columns(
      active: false,
      membership_state: 'current_member',
      mailing_latitude: 45.582,
      mailing_longitude: -122.682,
      mailing_geocoded_at: Time.current
    )

    get member_map_url(include_inactive: '1')

    assert_response :success
    assert_includes response.body, 'Example User One'
    assert_select 'input[name=?][checked]', 'include_inactive'
  end

  test 'excludes banned mapped members even when inactive members are included' do
    users(:one).update_columns(
      active: false,
      membership_state: 'banned_member',
      mailing_latitude: 45.582,
      mailing_longitude: -122.682,
      mailing_geocoded_at: Time.current
    )

    get member_map_url(include_inactive: '1')

    assert_response :success
    assert_not_includes response.body, 'Example User One'
    markers = JSON.parse(css_select('#member-map').first['data-markers'])
    assert_not_includes markers.map { |marker| marker.fetch('name') }, 'Example User One'
  end

  test 'shows all mapped members ordered by distance' do
    near_member = users(:one)
    far_member = users(:two)
    near_member.update_columns(
      active: true,
      mailing_latitude: 45.582,
      mailing_longitude: -122.682,
      mailing_geocoded_at: Time.current
    )
    far_member.update_columns(
      active: true,
      mailing_latitude: 46.2,
      mailing_longitude: -122.682,
      mailing_geocoded_at: Time.current
    )

    get member_map_url

    assert_response :success
    markers = JSON.parse(css_select('#member-map').first['data-markers'])
    marker_names = markers.map { |marker| marker.fetch('name') }
    assert_includes marker_names, near_member.display_name
    assert_includes marker_names, far_member.display_name
    assert_operator marker_names.index(near_member.display_name), :<, marker_names.index(far_member.display_name)

    near_position = response.body.index(near_member.display_name)
    far_position = response.body.index(far_member.display_name)
    assert_operator near_position, :<, far_position
  end

  test 'member list uses name links without row chevrons' do
    users(:one).update_columns(
      active: true,
      mailing_latitude: 45.582,
      mailing_longitude: -122.682,
      mailing_geocoded_at: Time.current
    )

    get member_map_url

    assert_response :success
    assert_select '.list-group-item .item-title a', text: 'Example User One'
    assert_select '.list-group-item .chevron', false
  end

  private

  def sign_in_as_admin
    account = local_accounts(:active_admin)
    post local_login_path, params: {
      session: { email: account.email, password: 'localpassword123' }
    }
  end
end
