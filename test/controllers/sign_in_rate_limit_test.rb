require 'test_helper'

# Proves the unauthenticated endpoints are actually limited. Worth testing explicitly rather than
# trusting the declarations: rate_limit takes its counter store from Rails.cache unless told
# otherwise, and Rails.cache in this environment is :null_store — which counts nothing and would
# make every one of these limits a no-op that nobody noticed.
#
# The attempts below use addresses that match no account on purpose. A real account would mean a
# bcrypt comparison per attempt, and twenty of those is several seconds spent proving nothing: the
# counters are incremented by the request arriving, not by the password being wrong.
class SignInRateLimitTest < ActionDispatch::IntegrationTest
  LOCAL_LOGIN_ADDRESS_LIMIT = 20
  LOCAL_LOGIN_ACCOUNT_LIMIT = 10
  RFID_PIN_LIMIT = 60
  RFID_POLL_LIMIT = 300
  LOGIN_LINK_ADDRESS_LIMIT = 15
  LOGIN_LINK_IDENTIFIER_LIMIT = 3

  setup do
    reset_rfid_webhook_state!
    @local_account = local_accounts(:active_admin)
    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
    reset_rfid_webhook_state!
  end

  # If this fails, every other test in this file is passing for the wrong reason.
  test 'the counter store actually counts' do
    store = RateLimiting.store

    assert_equal 1, store.increment('rate-limit-self-check', 1, expires_in: 1.minute)
    assert_equal 2, store.increment('rate-limit-self-check', 1, expires_in: 1.minute)
  end

  test 'the counter store is not the application cache' do
    assert_not_equal Rails.cache.class, RateLimiting.store.class,
                     'sharing Rails.cache would mean :null_store silently disabled every limit'
  end

  test 'password sign-in is refused after too many attempts from one address' do
    LOCAL_LOGIN_ADDRESS_LIMIT.times do |index|
      attempt_local_login("nobody-#{index}@example.com")
      assert_response :unprocessable_entity
    end

    attempt_local_login('nobody-last@example.com')

    assert_redirected_to login_path
    follow_redirect!
    assert_match 'Too many attempts', response.body
  end

  # The address limit does nothing against a botnet. This one is keyed to the account being
  # attempted, which is the part an attacker spread over many addresses cannot avoid.
  test 'password sign-in is refused after too many attempts on one account' do
    LOCAL_LOGIN_ACCOUNT_LIMIT.times do
      attempt_local_login('victim@example.com')
      assert_response :unprocessable_entity
    end

    attempt_local_login('victim@example.com')

    assert_redirected_to login_path
  end

  test 'a correct password still works below the limit' do
    3.times { attempt_local_login('nobody@example.com') }

    attempt_local_login(@local_account.email, 'localpassword123')

    assert_redirected_to root_path
  end

  # Accounts must not share a counter, or one member fumbling their password would lock out
  # everyone else behind the same address.
  test 'the account limit follows the account, not the caller' do
    LOCAL_LOGIN_ACCOUNT_LIMIT.times { attempt_local_login('victim@example.com') }

    attempt_local_login(@local_account.email, 'localpassword123')

    assert_redirected_to root_path, 'a different account must have its own count'
  end

  test 'keyfob PIN submissions are capped' do
    RFID_PIN_LIMIT.times { post rfid_submit_pin_path, params: { pin: '0000' } }

    post rfid_submit_pin_path, params: { pin: '0000' }

    assert_redirected_to login_path
    follow_redirect!
    assert_match 'Too many attempts', response.body
  end

  # The wait page polls every two seconds and a makerspace shares one address, so this limit has to
  # stay loose enough for a queue of people signing in at once — roughly ten simultaneous waiters.
  test 'the keyfob poll tolerates realistic polling and then refuses in JSON' do
    post rfid_login_path

    RFID_POLL_LIMIT.times do
      get rfid_check_webhook_path
      assert_response :success
    end

    get rfid_check_webhook_path

    assert_response :too_many_requests
    assert_equal 'rate_limited', response.parsed_body['status']
  end

  test 'login link requests are capped per address' do
    LOGIN_LINK_ADDRESS_LIMIT.times do |index|
      post request_login_link_path, params: { identifier: "nobody-#{index}@example.com" }
      assert_redirected_to login_path
    end

    post request_login_link_path, params: { identifier: 'nobody-last@example.com' }

    follow_redirect!
    assert_match 'Too many attempts', response.body
  end

  # Asking for a link replaces the member's token, so repeated requests invalidate the link they
  # are in the middle of using. Three an hour is already generous.
  test 'login link requests are capped per identifier' do
    identifier = users(:one).email

    LOGIN_LINK_IDENTIFIER_LIMIT.times do
      post request_login_link_path, params: { identifier: identifier }
      assert_redirected_to login_path
    end

    assert_no_enqueued_emails do
      post request_login_link_path, params: { identifier: identifier }
    end

    follow_redirect!
    assert_match 'Too many attempts', response.body
  end

  test 'a refused request is reported and not merely logged' do
    report = assert_error_reported(ErrorReporting::MemberZoneError) do
      (RFID_PIN_LIMIT + 1).times { post rfid_submit_pin_path, params: { pin: '0000' } }
    end

    assert_equal ErrorReporting::SOURCE, report.source
    assert_match 'rate limit exceeded', report.error.message
    assert_equal 'sessions', report.context[:controller]
  end

  private

  def attempt_local_login(email, password = 'wrongpassword')
    post local_login_path, params: { session: { email: email, password: password } }
  end
end
