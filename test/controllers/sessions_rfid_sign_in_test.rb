require 'test_helper'

# The keyfob sign-in path, end to end through the controller: a reader posts a scan, a browser
# claims it, and a PIN finishes the sign-in. Guards the two properties that were missing —
# a scan belongs to one session, and a PIN gets a limited number of guesses.
class SessionsRfidSignInTest < ActionDispatch::IntegrationTest
  setup do
    reset_rfid_webhook_state!
    @member = users(:one)
    @rfid = unique_rfid
    @pin = '4321'
    Rfid.create!(user: @member, rfid: @rfid)
  end

  teardown do
    reset_rfid_webhook_state!
  end

  test 'a scan and the right PIN signs the member in' do
    start_waiting_for_keyfob
    scan_keyfob

    get rfid_wait_path
    assert_redirected_to rfid_verify_path

    get rfid_verify_path
    assert_response :success

    post rfid_submit_pin_path, params: { pin: @pin }
    assert_redirected_to root_path
    assert_equal @member.id, session[:user_id]
  end

  test 'the wait page reports waiting until a scan arrives' do
    start_waiting_for_keyfob

    get rfid_wait_path
    assert_response :success

    get rfid_check_webhook_path
    assert_equal 'waiting', response.parsed_body['status']

    scan_keyfob

    get rfid_check_webhook_path
    assert_equal 'ready', response.parsed_body['status']
  end

  test 'polling without having started says so rather than claiming a scan' do
    scan_keyfob

    get rfid_check_webhook_path

    assert_equal 'no_session', response.parsed_body['status']
  end

  test 'a wrong PIN returns to the form and the scan survives' do
    reach_pin_entry

    post rfid_submit_pin_path, params: { pin: '0000' }

    assert_redirected_to rfid_verify_path
    assert_nil session[:user_id]
    assert_not_nil RfidWebhookService.retrieve(@rfid), 'one typo must not cost the scan'
  end

  test 'the form says how many guesses are left once one is spent' do
    reach_pin_entry
    post rfid_submit_pin_path, params: { pin: '0000' }

    get rfid_verify_path

    assert_response :success
    assert_match(/#{RfidWebhookService::MAX_PIN_ATTEMPTS - 1} attempts left/, response.body)
  end

  # The change that matters. Before this, a wrong PIN left the scan in Redis for its full five
  # minutes and nothing counted the guesses, so all 10,000 codes were available.
  test 'the scan is spent after too many wrong PINs and the member is sent back to the start' do
    reach_pin_entry

    (RfidWebhookService::MAX_PIN_ATTEMPTS - 1).times do
      post rfid_submit_pin_path, params: { pin: '0000' }
      assert_redirected_to rfid_verify_path
    end

    post rfid_submit_pin_path, params: { pin: '0000' }

    assert_redirected_to login_path
    assert_nil session[:user_id]
    assert_nil session[:pending_rfid]
    assert_nil RfidWebhookService.retrieve(@rfid)
  end

  test 'the right PIN no longer works once the guesses are spent' do
    reach_pin_entry
    RfidWebhookService::MAX_PIN_ATTEMPTS.times { post rfid_submit_pin_path, params: { pin: '0000' } }

    post rfid_submit_pin_path, params: { pin: @pin }

    assert_redirected_to login_path
    assert_nil session[:user_id]
  end

  # A bystander browser used to pick up whatever scan was made at the door next, then guess at
  # that member's PIN. Now the first session to claim a scan is the only one that sees it.
  test 'a second browser cannot pick up a scan another browser has claimed' do
    member_browser = open_session
    bystander = open_session

    member_browser.post rfid_login_path
    bystander.post rfid_login_path

    scan_keyfob

    member_browser.get rfid_check_webhook_path
    assert_equal 'ready', member_browser.response.parsed_body['status']

    bystander.get rfid_check_webhook_path
    assert_equal 'waiting', bystander.response.parsed_body['status'],
                 'the scan was already claimed and must not be offered twice'

    bystander.get rfid_verify_path
    assert_predicate bystander.response, :redirect?
    assert_includes bystander.response.location, rfid_wait_path
  end

  test 'a PIN submitted without holding the claim is refused' do
    start_waiting_for_keyfob
    scan_keyfob
    get rfid_wait_path

    # Somebody else's claim on the same scan, as if the session token had been guessed or replayed.
    RfidWebhookService.discard(@rfid)
    RfidWebhookService.store(@rfid, @pin)
    RfidWebhookService.claim_recent(1.minute.ago, 'someone-elses-token')

    post rfid_submit_pin_path, params: { pin: @pin }

    assert_redirected_to login_path
    assert_nil session[:user_id]
  end

  test 'the PIN form is not shown once the scan has expired' do
    reach_pin_entry
    RfidWebhookService.discard(@rfid)

    get rfid_verify_path

    assert_redirected_to rfid_wait_path
  end

  test 'a blank PIN is asked for again rather than counted as a wrong guess' do
    reach_pin_entry

    post rfid_submit_pin_path, params: { pin: '' }

    assert_redirected_to rfid_verify_path
    assert_equal 0, RfidWebhookService.failed_attempts(@rfid)
  end

  test 'a scan belonging to no member does not sign anyone in' do
    orphan = unique_rfid
    start_waiting_for_keyfob
    RfidWebhookService.store(orphan, @pin, 1, 'Front Door Reader')
    get rfid_wait_path

    post rfid_submit_pin_path, params: { pin: @pin }

    assert_redirected_to login_path
    assert_nil session[:user_id]
  end

  test 'an inactive member cannot sign in with a keyfob' do
    @member.update_columns(active: false)
    reach_pin_entry

    post rfid_submit_pin_path, params: { pin: @pin }

    assert_redirected_to login_path
    assert_nil session[:user_id]
  end

  private

  def start_waiting_for_keyfob
    post rfid_login_path
    assert_redirected_to rfid_wait_path
  end

  def scan_keyfob(rfid = @rfid, pin = @pin)
    RfidWebhookService.store(rfid, pin, rfid_readers(:one).id, rfid_readers(:one).name)
  end

  # Gets a session as far as the PIN box, holding the claim on a scan.
  def reach_pin_entry
    start_waiting_for_keyfob
    scan_keyfob
    get rfid_wait_path
    assert_redirected_to rfid_verify_path
  end
end
