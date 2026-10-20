require 'test_helper'

class RfidsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true
    sign_in_as_admin
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  test 'new key fob form defaults rfid field to configured facility code prefix' do
    DefaultSetting.instance.update!(rfid_facility_code: 127)

    get new_rfid_url(rfid: { user_id: users(:one).id })

    assert_response :success
    assert_select 'input[name=?][value=?]', 'rfid[rfid]', '127,'
  end

  test 'new key fob form includes pause and resume key access controls' do
    get new_rfid_url

    assert_response :success
    assert_select '#key_access_controls'
    assert_select 'form#pause_access_form'
    assert_select 'form#resume_access_form'
  end

  test 'new key fob form marks members with paused key access' do
    users(:one).pause_key_access!

    get new_rfid_url

    assert_response :success
    assert_select ".member-result[data-user-id=?][data-key-access-paused='true']", users(:one).id.to_s
  end

  test 'destroying a key fob notifies that access controllers are syncing' do
    rfid = rfids(:one)
    user = rfid.user

    assert_enqueued_with(job: AccessControllerMemberKeysSyncJob) do
      delete rfid_path(rfid)
    end

    assert_redirected_to user_path(user)
    follow_redirect!
    assert_match(/Key fob removed/i, response.body)
    assert_match(/syncing/i, response.body)
  end

  private

  def sign_in_as_admin
    account = local_accounts(:active_admin)
    post local_login_path, params: {
      session: { email: account.email, password: 'localpassword123' }
    }
  end
end
