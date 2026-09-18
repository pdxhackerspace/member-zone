require 'application_system_test_case'

# The keyfob sign-in is the one flow in the app that cannot be tested any other way. It spans two
# actors — a reader posting to a webhook, and a browser polling for the scan — and the step that
# joins them is JavaScript on the wait page calling /rfid_login/check_webhook every two seconds.
# A controller test can call each action in turn, but only a browser proves the page actually
# notices the scan and moves on.
class KeyfobSignInTest < ApplicationSystemTestCase
  setup do
    reset_rfid_webhook_state!
    @member = users(:one)
    @rfid = unique_rfid
    @pin = '4321'
    Rfid.create!(user: @member, rfid: @rfid)
    DefaultSetting.instance.update!(login_keyfob_sign_in_enabled: true)
  end

  teardown do
    reset_rfid_webhook_state!
  end

  test 'a member badges in, enters their PIN, and is signed in' do
    visit login_path
    click_on 'Sign In with Keyfob'

    assert_text 'Waiting for Keyfob Scan'

    scan_keyfob

    # The poll notices the scan and moves the page on by itself.
    assert_text 'Enter Verification Code', wait: 10
    assert_text 'Front Door Reader'

    fill_in 'pin', with: @pin
    click_on 'Verify and Sign In'

    assert_signed_in_as_member
  end

  test 'a wrong PIN can be corrected without badging in again' do
    reach_pin_entry

    fill_in 'pin', with: '0000'
    click_on 'Verify and Sign In'

    assert_text 'Invalid code'
    assert_text "#{RfidWebhookService::MAX_PIN_ATTEMPTS - 1} attempts left"

    fill_in 'pin', with: @pin
    click_on 'Verify and Sign In'

    assert_signed_in_as_member
  end

  test 'running out of guesses sends the member back to badge in again' do
    reach_pin_entry

    RfidWebhookService::MAX_PIN_ATTEMPTS.times do
      fill_in 'pin', with: '0000'
      click_on 'Verify and Sign In'
    end

    assert_text 'Too many incorrect codes'
    assert_current_path login_path
    assert_nil RfidWebhookService.retrieve(@rfid)
  end

  test 'cancelling returns to the sign-in page' do
    reach_pin_entry

    click_on 'Cancel'

    assert_current_path login_path
  end

  test 'the keyfob button is absent when the setting is off' do
    DefaultSetting.instance.update!(login_keyfob_sign_in_enabled: false)

    visit login_path

    assert_no_button 'Sign In with Keyfob'
  end

  private

  # Asserted on the landing page rather than on the "Signed in via keyfob" notice, because that
  # notice never reaches the member: sign-in redirects to root, root is the admin dashboard, and
  # bouncing a plain member from there to their own page sets an alert of its own, which replaces
  # the flash on the way through. Ending up on their own dashboard is the durable evidence.
  def assert_signed_in_as_member
    assert_text "Hi, #{@member.display_name}"
    assert_text 'Sign out'
  end

  def scan_keyfob(rfid = @rfid, pin = @pin)
    reader = rfid_readers(:one)
    RfidWebhookService.store(rfid, pin, reader.id, reader.name)
  end

  def reach_pin_entry
    visit login_path
    click_on 'Sign In with Keyfob'
    assert_text 'Waiting for Keyfob Scan'
    scan_keyfob
    assert_text 'Enter Verification Code', wait: 10
  end
end
