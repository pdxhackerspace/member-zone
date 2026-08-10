require 'test_helper'
require 'active_job/test_helper'

class SheetEntriesControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @sheet_entry = sheet_entries(:member_list_entry)
    @local_account = local_accounts(:active_admin)
    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true
    log_in_local_user
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  test 'shows index' do
    get sheet_entries_path
    assert_response :success
    assert_select 'h1', text: 'Sheet Entries'
    assert_match @sheet_entry.name, response.body
  end

  test 'index does not show the email column' do
    get sheet_entries_path

    assert_response :success
    assert_select 'th', text: 'Email', count: 0
    assert_select 'a[href^=?]', 'mailto:', count: 0
  end

  test 'shows a single entry' do
    get sheet_entry_path(@sheet_entry)
    assert_response :success
    assert_match @sheet_entry.name, response.body
    assert_match @sheet_entry.status, response.body
  end

  test 'show masks email and raw data with reveal control' do
    get sheet_entry_path(@sheet_entry)

    assert_response :success
    assert_select '[data-controller=?]', 'sensitive-reveal'
    assert_select '[data-action=?]', 'click->sensitive-reveal#toggle', text: /Show contact details/
    assert_select '[data-sensitive-reveal-target=?]', 'blurred', text: /user1@example\.com/
    assert_select 'pre[data-sensitive-reveal-target=?]', 'blurred', text: /Owner/
  end

  test 'enqueues sync job' do
    assert_enqueued_with(job: GoogleSheets::SyncJob) do
      post sync_sheet_entries_path
    end
    assert_redirected_to sheet_entries_path
  end

  # ─── Disabled Source Guards ──────────────────────────────────────

  test 'sync redirects with alert when sheet source is disabled' do
    member_sources(:sheet).update!(enabled: false)

    assert_no_enqueued_jobs(only: GoogleSheets::SyncJob) do
      post sync_sheet_entries_path
    end
    assert_redirected_to sheet_entries_path
    assert_equal 'Google Sheet source is disabled.', flash[:alert]
  end

  test 'sync_to_users redirects with alert when sheet source is disabled' do
    member_sources(:sheet).update!(enabled: false)

    post sync_to_users_sheet_entries_path
    assert_redirected_to sheet_entries_path
    assert_equal 'Google Sheet source is disabled.', flash[:alert]
  end

  test 'sync_to_user links matching member without copying sheet data' do
    user = users(:one)
    @sheet_entry.update_columns(user_id: nil, rfid: 'RFID-SHOULD-NOT-COPY', status: '')
    user.update_columns(active: true, payment_type: 'paypal', membership_state: 'current_member',
                        membership_status: 'paying', notes: nil)

    post sync_to_user_sheet_entry_path(@sheet_entry)

    assert_redirected_to sheet_entry_path(@sheet_entry)
    assert_equal user.id, @sheet_entry.reload.user_id

    user.reload
    assert user.active?
    assert_equal 'paypal', user.payment_type
    assert_equal 'paying', user.membership_status
    assert_nil user.notes
    assert_not Rfid.exists?(user: user, rfid: 'RFID-SHOULD-NOT-COPY')
  end

  test 'unlink_user disassociates sheet entry from member' do
    user = users(:one)
    @sheet_entry.update!(user: user)

    post unlink_user_sheet_entry_path(@sheet_entry)

    assert_redirected_to sheet_entry_path(@sheet_entry)
    assert_nil @sheet_entry.reload.user_id
  end

  private

  def log_in_local_user
    post local_login_path, params: {
      session: {
        email: @local_account.email,
        password: 'localpassword123'
      }
    }
    follow_redirect!
  end
end
