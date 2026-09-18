require 'test_helper'

# WebhooksController had no tests at all, which is part of how "verify the secret if one is set"
# survived as long as it did. These cover the authentication decision specifically: what happens
# with a good secret, a bad one, and — the case that mattered — none configured.
class WebhooksControllerTest < ActionDispatch::IntegrationTest
  setup do
    @kofi = incoming_webhooks(:kofi_webhook)
    @rfid_webhook = incoming_webhooks(:rfid_webhook)
    reset_rfid_webhook_state!
  end

  teardown do
    reset_rfid_webhook_state!
  end

  test 'an unknown slug is not found' do
    post webhook_receive_path(slug: 'no-such-webhook')

    assert_response :not_found
  end

  test 'a disabled webhook is not found' do
    @kofi.update!(enabled: false)

    post webhook_receive_path(slug: @kofi.slug), params: { data: default_kofi_payload.to_json }

    assert_response :not_found
  end

  # Ko-Fi

  test 'a Ko-Fi payment with the right token is recorded' do
    with_env('KOFI_VERIFICATION_TOKEN' => 'kofi-secret') do
      assert_difference -> { KofiPayment.count }, 1 do
        post_kofi(verification_token: 'kofi-secret')
      end
    end

    assert_response :success
  end

  test 'a Ko-Fi payment with the wrong token is refused and records nothing' do
    with_env('KOFI_VERIFICATION_TOKEN' => 'kofi-secret') do
      assert_no_difference -> { KofiPayment.count } do
        post_kofi(verification_token: 'not-the-secret')
      end
    end

    assert_response :unauthorized
  end

  test 'a Ko-Fi payment with no token at all is refused' do
    with_env('KOFI_VERIFICATION_TOKEN' => 'kofi-secret') do
      assert_no_difference -> { KofiPayment.count } do
        post_kofi({})
      end
    end

    assert_response :unauthorized
  end

  # The whole point. An unset token used to mean "this endpoint needs no authentication", so a
  # missing environment variable turned a payment feed into an anonymous write path.
  test 'Ko-Fi payments are refused when the token is not configured' do
    WebhookVerification.with_required(true) do
      with_env('KOFI_VERIFICATION_TOKEN' => nil) do
        assert_no_difference -> { KofiPayment.count } do
          post_kofi(verification_token: 'anything')
        end
      end
    end

    assert_response :unauthorized
  end

  test 'an unconfigured secret is reported rather than only logged' do
    report = assert_error_reported(ErrorReporting::MemberZoneError) do
      WebhookVerification.with_required(true) do
        with_env('KOFI_VERIFICATION_TOKEN' => nil) { post_kofi(verification_token: 'anything') }
      end
    end

    assert_match 'KOFI_VERIFICATION_TOKEN', report.error.message
    assert_equal :error, report.severity
  end

  # Development and test would otherwise need five secrets set to try a webhook by hand, which only
  # teaches people to set them all to "x".
  test 'an unconfigured secret is accepted where that is explicitly permitted' do
    WebhookVerification.with_required(false) do
      with_env('KOFI_VERIFICATION_TOKEN' => nil) do
        assert_difference -> { KofiPayment.count }, 1 do
          post_kofi({})
        end
      end
    end

    assert_response :success
  end

  test 'a Ko-Fi webhook with no data is a bad request' do
    with_env('KOFI_VERIFICATION_TOKEN' => 'kofi-secret') do
      post webhook_receive_path(slug: @kofi.slug)
    end

    assert_response :bad_request
  end

  test 'unparseable Ko-Fi data is refused and reported' do
    assert_error_reported(JSON::ParserError) do
      with_env('KOFI_VERIFICATION_TOKEN' => 'kofi-secret') do
        post webhook_receive_path(slug: @kofi.slug), params: { data: 'this is not json' }
      end
    end

    assert_response :bad_request
  end

  # Recharge

  test 'a Recharge webhook with a valid signature is accepted' do
    payload = { 'subscription' => { 'id' => 1 } }.to_json

    with_env('RECHARGE_WEBHOOK_SECRET' => 'recharge-secret') do
      post_recharge(payload, signature: recharge_hmac(payload, 'recharge-secret'))
    end

    assert_response :success
  end

  test 'a Recharge webhook with a bad signature is refused' do
    payload = { 'subscription' => { 'id' => 1 } }.to_json

    with_env('RECHARGE_WEBHOOK_SECRET' => 'recharge-secret') do
      post_recharge(payload, signature: recharge_hmac(payload, 'the-wrong-secret'))
    end

    assert_response :unauthorized
  end

  test 'a Recharge webhook with no signature is refused' do
    with_env('RECHARGE_WEBHOOK_SECRET' => 'recharge-secret') do
      post_recharge({ 'subscription' => {} }.to_json, signature: nil)
    end

    assert_response :unauthorized
  end

  test 'Recharge webhooks are refused when the secret is not configured' do
    payload = { 'subscription' => {} }.to_json

    WebhookVerification.with_required(true) do
      with_env('RECHARGE_WEBHOOK_SECRET' => nil) do
        post_recharge(payload, signature: recharge_hmac(payload, 'anything'))
      end
    end

    assert_response :unauthorized
  end

  # Authentik

  test 'an Authentik webhook with the right secret is accepted' do
    with_env('AUTHENTIK_WEBHOOK_SECRET' => 'authentik-secret') do
      post_authentik({ 'body' => 'ignored' }.to_json, secret: 'authentik-secret')
    end

    assert_response :success
  end

  test 'an Authentik webhook with the wrong secret is refused' do
    with_env('AUTHENTIK_WEBHOOK_SECRET' => 'authentik-secret') do
      post_authentik({ 'body' => 'ignored' }.to_json, secret: 'guess')
    end

    assert_response :unauthorized
  end

  test 'Authentik webhooks are refused when the secret is not configured' do
    WebhookVerification.with_required(true) do
      with_env('AUTHENTIK_WEBHOOK_SECRET' => nil) do
        post_authentik({ 'body' => 'ignored' }.to_json, secret: 'anything')
      end
    end

    assert_response :unauthorized
  end

  # Access logs

  test 'an access log line with the right key is recorded' do
    with_env('ACCESS_WEBHOOK_KEY' => 'access-key') do
      assert_difference -> { AccessLog.count }, 1 do
        post_access(key: 'access-key')
      end
    end

    assert_response :created
  end

  test 'an access log line with the wrong key is refused' do
    with_env('ACCESS_WEBHOOK_KEY' => 'access-key') do
      assert_no_difference -> { AccessLog.count } do
        post_access(key: 'wrong')
      end
    end

    assert_response :unauthorized
  end

  test 'access log lines are refused when the key is not configured' do
    WebhookVerification.with_required(true) do
      with_env('ACCESS_WEBHOOK_KEY' => nil) do
        assert_no_difference -> { AccessLog.count } do
          post_access(key: 'anything')
        end
      end
    end

    assert_response :unauthorized
  end

  # RFID. This handler always failed closed on a blank allowlist; the test pins that in place.

  test 'an RFID scan from an allowed address is stored' do
    rfid = unique_rfid

    with_env('RFID_WEBHOOK_IP_WHITELIST' => '127.0.0.1') do
      post webhook_receive_path(slug: @rfid_webhook.slug),
           params: { key: rfid_readers(:one).key, rfid: rfid, pin: '1234' }
    end

    assert_response :success
    assert_equal '1234', RfidWebhookService.retrieve(rfid)[:pin]
  end

  test 'an RFID scan is refused when the allowlist is not configured' do
    rfid = unique_rfid

    with_env('RFID_WEBHOOK_IP_WHITELIST' => nil) do
      post webhook_receive_path(slug: @rfid_webhook.slug),
           params: { key: rfid_readers(:one).key, rfid: rfid, pin: '1234' }
    end

    assert_response :forbidden
    assert_nil RfidWebhookService.retrieve(rfid)
  end

  test 'an RFID scan from an address outside the allowlist is refused' do
    with_env('RFID_WEBHOOK_IP_WHITELIST' => '10.0.0.0/8') do
      post webhook_receive_path(slug: @rfid_webhook.slug),
           params: { key: rfid_readers(:one).key, rfid: unique_rfid, pin: '1234' }
    end

    assert_response :forbidden
  end

  test 'an RFID scan with an unknown reader key is refused' do
    with_env('RFID_WEBHOOK_IP_WHITELIST' => '127.0.0.1') do
      post webhook_receive_path(slug: @rfid_webhook.slug),
           params: { key: 'not-a-reader', rfid: unique_rfid, pin: '1234' }
    end

    assert_response :unauthorized
  end

  test 'an RFID scan with a PIN that is not four digits is refused' do
    with_env('RFID_WEBHOOK_IP_WHITELIST' => '127.0.0.1') do
      post webhook_receive_path(slug: @rfid_webhook.slug),
           params: { key: rfid_readers(:one).key, rfid: unique_rfid, pin: 'abcd' }
    end

    assert_response :bad_request
  end

  private

  # ENV is process-wide and the suite runs in parallel, but each worker is its own process, so
  # setting a variable for the length of one example only affects that worker.
  def with_env(values)
    originals = values.keys.index_with { |key| ENV.fetch(key, nil) }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    originals.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def post_kofi(data)
    post webhook_receive_path(slug: @kofi.slug),
         params: { data: default_kofi_payload.merge(data.stringify_keys).to_json }
  end

  def default_kofi_payload
    {
      'kofi_transaction_id' => SecureRandom.uuid,
      'message_id' => SecureRandom.uuid,
      'type' => 'Donation',
      'amount' => '25.00',
      'currency' => 'USD',
      'from_name' => 'A Supporter',
      'email' => 'supporter@example.com',
      'timestamp' => Time.current.iso8601
    }
  end

  def post_recharge(payload, signature:)
    headers = { 'X-Recharge-Topic' => 'subscription/created', 'CONTENT_TYPE' => 'application/json' }
    headers['X-Recharge-Hmac-Sha256'] = signature if signature
    post webhook_receive_path(slug: recharge_webhook.slug), params: payload, headers: headers
  end

  def recharge_hmac(payload, secret)
    Base64.strict_encode64(OpenSSL::HMAC.digest('sha256', secret, payload))
  end

  def post_authentik(payload, secret:)
    post webhook_receive_path(slug: authentik_webhook.slug),
         params: payload,
         headers: { 'X-Authentik-Secret' => secret, 'CONTENT_TYPE' => 'application/json' }
  end

  def post_access(key:)
    post webhook_receive_path(slug: access_webhook.slug), params: { key: key, line: access_log_line }
  end

  # webhook_type is unique, and the fixtures already hold the only 'access' row — so this enables
  # that one rather than adding a second.
  def access_webhook
    @access_webhook ||= incoming_webhooks(:disabled_webhook).tap { |webhook| webhook.update!(enabled: true) }
  end

  def recharge_webhook
    @recharge_webhook ||= IncomingWebhook.create!(
      name: 'Recharge', webhook_type: 'recharge', slug: 'recharge-test', enabled: true
    )
  end

  def authentik_webhook
    @authentik_webhook ||= IncomingWebhook.create!(
      name: 'Authentik', webhook_type: 'authentik', slug: 'authentik-test', enabled: true
    )
  end

  # Pattern 1 shape, the one AccessLogParser recognises:
  # "<date> <host> accesscontrol[<pid>]: <name> has <action> <location>"
  def access_log_line
    'Nov 15 14:41:35 unit2 accesscontrol[2113]: Example User One has opened unit2 front door'
  end
end
