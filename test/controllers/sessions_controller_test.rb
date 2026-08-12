require 'test_helper'

class SessionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @local_account = local_accounts(:active_admin)
    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  test 'local login signs in the user' do
    post local_login_path, params: {
      session: {
        email: @local_account.email,
        password: 'localpassword123'
      }
    }

    assert_redirected_to root_path
    follow_redirect!
    assert_response :success
    assert_match 'Signed in locally', response.body
  end

  test 'local login fails with bad credentials' do
    post local_login_path, params: {
      session: {
        email: @local_account.email,
        password: 'wrongpassword'
      }
    }

    assert_response :unprocessable_entity
    assert_select '.alert', /Invalid email or password/
  end

  test 'failed local login shows the error beside the sign-in form' do
    post local_login_path, params: {
      session: {
        email: @local_account.email,
        password: 'wrongpassword'
      }
    }

    # A page-level flash renders far above the form and reads as no response at all.
    assert_select '.card-body .alert-danger', /Invalid email or password/
    assert_equal 1, response.body.scan('Invalid email or password.').size,
                 'error should render once, not both inline and as a page-level flash'
  end

  test 'failed local login keeps the submitted email but not the password' do
    post local_login_path, params: {
      session: {
        email: @local_account.email,
        password: 'wrongpassword'
      }
    }

    assert_select 'input[name=?][value=?]', 'session[email]', @local_account.email
    assert_select 'input[name=?]', 'session[password]' do |inputs|
      assert_predicate inputs.first['value'].to_s, :empty?
    end
  end

  # Setting the encryption keys for the first time orphans the digest every local account was
  # found by. The form can only say "Invalid email or password", so the log has to say more.
  test 'a sign-in refused because the keys changed says so in the log' do
    @local_account.update_columns(email: "#{SensitiveData::STRING_PREFIX}encrypted-under-another-key")

    logged = capture_rails_log do
      post local_login_path, params: { session: { email: 'admin@example.com', password: 'localpassword123' } }
    end

    assert_response :unprocessable_entity
    assert_match 'DATABASE_FIELD_ENCRYPTION_KEY', logged
  end

  test 'login page renders no error before anything is submitted' do
    get login_path

    assert_response :success
    assert_select '.alert-danger', false
  end

  test 'login page renders configured branding and message' do
    setting = DefaultSetting.instance
    setting.login_branding_image.attach(
      io: StringIO.new('branding-image'),
      filename: 'branding.txt',
      content_type: 'text/plain'
    )
    setting.login_background_image.attach(
      io: StringIO.new('background-image'),
      filename: 'background.txt',
      content_type: 'text/plain'
    )
    TextFragment.ensure_exists!(
      key: 'login_screen_message',
      title: 'Login Screen Message',
      content: '<p>Custom login message</p>'
    )

    get login_path

    assert_response :success
    assert_match 'Custom login message', response.body
    assert_match 'Apply for Membership', response.body
    assert_match 'Continue with sign-in options', response.body
    assert_select 'img[alt="Organization branding"]'
  end

  test 'login page can hide keyfob sign-in button' do
    setting = DefaultSetting.instance
    setting.update!(login_keyfob_sign_in_enabled: false)

    get login_path

    assert_response :success
    assert_no_match 'Sign In with Keyfob', response.body
  end

  test 'rfid login redirects to wait page' do
    post rfid_login_path
    assert_redirected_to rfid_wait_path
  end

  test 'rfid wait without session redirects to login' do
    get rfid_wait_path
    assert_redirected_to login_path
  end

  test 'rfid login stores session timestamp' do
    post rfid_login_path
    assert_redirected_to rfid_wait_path
    follow_redirect!
    assert_response :success
  end

  private

  def capture_rails_log
    buffer = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new(buffer))
    yield
    buffer.string
  ensure
    Rails.logger = original
  end
end
