# SPDX-FileCopyrightText: 2025 John Romkey
#
# SPDX-License-Identifier: CC0-1.0

require 'ipaddr'

class WebhooksController < ApplicationController
  # CSRF verification is intentionally skipped: all webhook endpoints receive
  # machine-to-machine POST requests from external services (Ko-Fi, Authentik,
  # Recharge, RFID hardware) that cannot include Rails session tokens.
  # Each handler enforces its own authentication (HMAC, shared secret, or API key).
  # codeql[rb/csrf-protection-disabled]: M2M endpoints; per-handler HMAC, shared secret, or API key.
  skip_before_action :verify_authenticity_token

  # Dynamic dispatch based on incoming webhook slug
  def receive
    @incoming_webhook = IncomingWebhook.find_enabled_by_slug(params[:slug])

    unless @incoming_webhook
      Rails.logger.warn("Webhook request for unknown or disabled slug: #{params[:slug]} from #{client_ip}")
      head :not_found
      return
    end

    case @incoming_webhook.webhook_type
    when 'rfid'
      rfid
    when 'kofi'
      kofi
    when 'access'
      access
    when 'authentik'
      authentik
    when 'recharge'
      recharge
    else
      head :not_found
    end
  end

  # Ko-Fi webhook endpoint
  # Ko-Fi sends POST requests with form data containing a "data" field which is a JSON string
  # See: https://help.ko-fi.com/hc/en-us/articles/360004162298-Does-Ko-fi-have-an-API-or-webhook
  def kofi
    # Parse the incoming data (Ko-Fi sends it as a form field named 'data')
    raw_data = params[:data]
    if raw_data.blank?
      Rails.logger.warn('Ko-Fi webhook received with no data')
      head :bad_request
      return
    end

    # Parse the JSON data
    data = JSON.parse(raw_data)

    # Ko-Fi puts its token in the payload rather than a header, so this can only be checked
    # after parsing — but it is still checked before anything is written.
    unless valid_kofi_webhook?(data)
      Rails.logger.warn("Ko-Fi webhook verification failed from #{client_ip}")
      head :unauthorized
      return
    end

    # Extract payment details from the webhook
    transaction_id = data['kofi_transaction_id']

    if transaction_id.blank?
      Rails.logger.warn("Ko-Fi webhook missing transaction ID: #{data.inspect}")
      head :bad_request
      return
    end

    # Find or create the payment record
    payment = KofiPayment.find_or_initialize_by(kofi_transaction_id: transaction_id)

    # Update payment attributes
    payment.message_id = data['message_id']
    payment.status = 'completed'
    payment.amount = BigDecimal(data['amount'].to_s) if data['amount'].present?
    payment.currency = data['currency'] || 'USD'
    payment.timestamp = Time.zone.parse(data['timestamp']) if data['timestamp'].present?
    payment.payment_type = data['type']
    payment.from_name = data['from_name']
    payment.email = data['email']
    payment.message = data['message']
    payment.url = data['url']
    payment.is_public = data['is_public'] == true
    payment.is_subscription_payment = data['is_subscription_payment'] == true
    payment.is_first_subscription_payment = data['is_first_subscription_payment'] == true
    payment.tier_name = data['tier_name']
    payment.shop_items = data['shop_items'] || []
    payment.raw_attributes = data
    payment.last_synced_at = Time.current

    # Try to find a matching user by email
    if payment.email.present?
      user = User.by_any_email(payment.email).first
      payment.user = user if user
    end

    was_new = payment.new_record? || payment.id_previously_changed?
    payment.save!

    if was_new
      event_type = payment.is_first_subscription_payment ? 'subscription_started' : 'payment'
      PaymentEvent.find_or_create_by!(source: 'kofi', external_id: transaction_id, event_type: event_type) do |pe|
        pe.user = payment.user
        pe.amount = payment.amount
        pe.currency = payment.currency || 'USD'
        pe.occurred_at = payment.timestamp || Time.current
        pe.details = "Ko-Fi #{payment.payment_type || 'payment'} from #{payment.from_name || payment.email}"
        pe.kofi_payment = payment
      end
    end

    # Record webhook received in processor
    processor = PaymentProcessor.for('kofi')
    processor.record_webhook_received!
    processor.refresh_statistics!

    Rails.logger.info(
      "Ko-Fi webhook processed: #{transaction_id} - " \
      "#{payment.payment_type} - #{payment.amount_with_currency} " \
      "from #{payment.from_name}"
    )

    head :ok
  rescue JSON::ParserError => e
    Rails.logger.error("Ko-Fi webhook JSON parse error: #{e.message}")
    ErrorReporting.report(e, context: { webhook: 'kofi', stage: 'parse' }, severity: :warning)
    head :bad_request
  rescue StandardError => e
    # A dropped Ko-Fi webhook is a payment the roster never hears about, so this needs to
    # reach someone rather than sit in the log.
    Rails.logger.error("Ko-Fi webhook error: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
    ErrorReporting.report(e, context: { webhook: 'kofi', transaction_id: transaction_id })
    head :internal_server_error
  end

  # Access control webhook endpoint
  # Receives access log lines in the same format as the log files
  # POST /webhooks/:slug (webhook_type: access)
  # Parameters:
  #   - line: The log line to process (required)
  #   - key: API key for authentication, from ACCESS_WEBHOOK_KEY (may also be sent as the
  #     X-Access-Key header). Required unless ALLOW_UNVERIFIED_WEBHOOKS is set.
  def access
    unless valid_access_webhook?
      Rails.logger.warn("Access webhook: invalid API key from #{client_ip}")
      head :unauthorized
      return
    end

    # Get the log line
    line = params[:line]
    if line.blank? || line.length > AccessLogParser::MAX_LINE_LENGTH
      render json: { error: 'line parameter is required and must be under 2000 characters' }, status: :bad_request
      return
    end

    begin
      parser = AccessLogParser.new(line)

      # Skip system messages
      if parser.should_skip?
        Rails.logger.debug { "Access webhook: skipping system message: #{line.truncate(100)}" }
        render json: { status: 'skipped', reason: 'system message' }, status: :ok
        return
      end

      # Parse and create the access log
      access_log = parser.create_access_log!

      Rails.logger.info(
        'Access webhook: created log entry - ' \
        "#{access_log.name || 'unknown'} #{access_log.action} " \
        "#{access_log.location}"
      )

      render json: {
        status: 'created',
        id: access_log.id,
        name: access_log.name,
        action: access_log.action,
        location: access_log.location,
        user_id: access_log.user_id,
        logged_at: access_log.logged_at&.iso8601
      }, status: :created
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error("Access webhook: validation error: #{e.message}")
      ErrorReporting.report(e, context: { webhook: 'access', stage: 'create_access_log' }, severity: :warning)
      render json: { error: e.message }, status: :unprocessable_content
    rescue StandardError => e
      Rails.logger.error("Access webhook error: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
      ErrorReporting.report(e, context: { webhook: 'access' })
      render json: { error: 'Internal error' }, status: :internal_server_error
    end
  end

  # Authentik webhook endpoint
  # Receives user change notifications from Authentik's event system
  # See: https://docs.goauthentik.io/docs/sys-mgmt/events/transports
  def authentik
    unless valid_authentik_webhook?
      Rails.logger.warn("[Authentik Webhook] Unauthorized request from #{client_ip}")
      render json: { error: 'Unauthorized' }, status: :unauthorized
      return
    end

    begin
      payload = JSON.parse(request.body.read)
      Rails.logger.info("[Authentik Webhook] Received payload from #{client_ip}")

      result = Authentik::WebhookHandler.new.call(payload)

      render json: { status: 'ok' }.merge(result)
    rescue JSON::ParserError => e
      Rails.logger.error("[Authentik Webhook] JSON parse error: #{e.message}")
      ErrorReporting.report(e, context: { webhook: 'authentik', stage: 'parse' }, severity: :warning)
      render json: { error: 'Invalid JSON' }, status: :bad_request
    rescue StandardError => e
      # Authentik is the one bidirectional integration, so a handler that fails halfway leaves
      # the local roster disagreeing with the identity provider.
      Rails.logger.error("[Authentik Webhook] Error: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
      ErrorReporting.report(e, context: { webhook: 'authentik' })
      render json: { error: 'Processing error' }, status: :unprocessable_content
    end
  end

  # Recharge subscription webhook endpoint
  # Receives subscription lifecycle events (created, cancelled) from Recharge
  # Validates the HMAC signature against RECHARGE_WEBHOOK_SECRET, and refuses the request when
  # that secret is not set.
  def recharge
    unless valid_recharge_webhook?
      Rails.logger.warn("[Recharge Webhook] HMAC validation failed from #{client_ip}")
      head :unauthorized
      return
    end

    topic = request.headers['X-Recharge-Topic']
    if topic.blank?
      Rails.logger.warn("[Recharge Webhook] Missing X-Recharge-Topic header from #{client_ip}")
      head :bad_request
      return
    end

    payload = JSON.parse(request.body.read)
    Rails.logger.info("[Recharge Webhook] Received #{topic} from #{client_ip}")

    result = Recharge::WebhookHandler.new(topic: topic, payload: payload).call
    render json: { status: 'ok' }.merge(result)
  rescue JSON::ParserError => e
    Rails.logger.error("[Recharge Webhook] JSON parse error: #{e.message}")
    ErrorReporting.report(e, context: { webhook: 'recharge', stage: 'parse' }, severity: :warning)
    head :bad_request
  rescue StandardError => e
    # Recharge carries subscription lifecycle events, so losing one can leave a member marked
    # as paying after they cancelled, or lapsed after they renewed.
    Rails.logger.error("[Recharge Webhook] Error: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
    ErrorReporting.report(e, context: { webhook: 'recharge', topic: request.headers['X-Recharge-Topic'] })
    head :internal_server_error
  end

  def rfid
    unless ip_whitelisted?
      Rails.logger.warn("Webhook request from non-whitelisted IP: #{client_ip}")
      head :forbidden
      return
    end

    # Validate reader key
    reader_key = params[:key] || params[:reader_key]
    if reader_key.blank?
      render json: { error: 'key is required' }, status: :bad_request
      return
    end

    reader = RfidReader.lookup_by_key(reader_key)
    unless reader
      Rails.logger.warn("Webhook request with invalid reader key: #{reader_key}")
      render json: { error: 'invalid key' }, status: :unauthorized
      return
    end

    rfid_code = params[:rfid] || params[:rfid_code]
    pin_code = params[:pin] || params[:pin_code] || params[:code]

    if rfid_code.blank? || pin_code.blank?
      render json: { error: 'rfid and pin are required' }, status: :bad_request
      return
    end

    # Validate pin is 4 digits
    unless pin_code.to_s.match?(/\A\d{4}\z/)
      render json: { error: 'pin must be 4 digits' }, status: :bad_request
      return
    end

    RfidWebhookService.store(rfid_code, pin_code.to_s.strip, reader.id, reader.name)
    Rails.logger.info(
      "RFID webhook received from #{reader.name}: RFID=#{RfidNormalizer.call(rfid_code)}, PIN=#{pin_code[0..1]}**"
    )

    head :ok
  end

  private

  # Runs a handler's authentication check, and owns the decision about what an unset secret means.
  #
  # Yields the secret when there is one, and the block returns whether the request authenticates.
  # When there is no secret the block never runs: the request is refused, unless
  # ALLOW_UNVERIFIED_WEBHOOKS says an unauthenticated one is acceptable here. See
  # config/initializers/webhook_verification.rb for why a blank secret no longer means
  # "this endpoint needs no authentication".
  def with_webhook_secret(env_var)
    secret = ENV.fetch(env_var, nil)
    return yield(secret) if secret.present?

    unless WebhookVerification.required?
      Rails.logger.warn("[Webhook] #{env_var} is unset; accepting an unverified request because " \
                        'ALLOW_UNVERIFIED_WEBHOOKS permits it')
      return true
    end

    refuse_unconfigured_webhook(env_var)
    false
  end

  # Loud on purpose: a missing secret is a deployment mistake that otherwise presents as an
  # integration which quietly stopped working.
  def refuse_unconfigured_webhook(env_var)
    message = "#{env_var} is not configured, so the webhook was refused"
    Rails.logger.error("[Webhook] #{message}. Set it, or set ALLOW_UNVERIFIED_WEBHOOKS to accept " \
                       'unauthenticated requests on purpose.')
    ErrorReporting.report_message("Webhook refused: #{message}",
                                  context: { env_var: env_var, slug: params[:slug] }, severity: :error)
  end

  def valid_recharge_webhook?
    with_webhook_secret('RECHARGE_WEBHOOK_SECRET') do |secret|
      body = request.body.read
      request.body.rewind
      provided_hmac = request.headers['X-Recharge-Hmac-Sha256']
      next false if provided_hmac.blank?

      computed_hmac = Base64.strict_encode64(
        OpenSSL::HMAC.digest('sha256', secret, body)
      )
      ActiveSupport::SecurityUtils.secure_compare(computed_hmac, provided_hmac)
    end
  end

  def valid_authentik_webhook?
    with_webhook_secret('AUTHENTIK_WEBHOOK_SECRET') do |secret|
      provided = request.headers['X-Authentik-Secret'] || params[:secret]
      next false if provided.blank?

      ActiveSupport::SecurityUtils.secure_compare(secret, provided.to_s)
    end
  end

  def valid_kofi_webhook?(data)
    with_webhook_secret('KOFI_VERIFICATION_TOKEN') do |token|
      provided = data['verification_token'].to_s
      next false if provided.blank?

      ActiveSupport::SecurityUtils.secure_compare(token, provided)
    end
  end

  def valid_access_webhook?
    with_webhook_secret('ACCESS_WEBHOOK_KEY') do |api_key|
      provided_key = params[:key] || request.headers['X-Access-Key']
      ActiveSupport::SecurityUtils.secure_compare(provided_key.to_s, api_key)
    end
  end

  # Already fails closed, and always did — an unset allowlist refuses everything. Kept that way;
  # the only change is saying which of the two reasons applied, because "not configured" and
  # "not on the list" call for completely different fixes and both used to log the same line.
  def ip_whitelisted?
    whitelist = ENV.fetch('RFID_WEBHOOK_IP_WHITELIST', nil)
    if whitelist.blank?
      refuse_unconfigured_webhook('RFID_WEBHOOK_IP_WHITELIST')
      return false
    end

    client_ip_address = client_ip
    return false if client_ip_address.blank?

    whitelist.split(',').map(&:strip).any? do |range|
      ip_in_range?(client_ip_address, range)
    end
  end

  def client_ip
    # Check X-Forwarded-For first (reverse proxy)
    forwarded_for = request.headers['X-Forwarded-For']
    if forwarded_for.present?
      # X-Forwarded-For can contain multiple IPs, take the first one
      return forwarded_for.split(',').first.strip
    end

    # Check X-Real-IP (another common reverse proxy header)
    real_ip = request.headers['X-Real-IP']
    return real_ip.strip if real_ip.present?

    # Fall back to remote_ip
    request.remote_ip
  end

  def ip_in_range?(ip, range)
    # Handle CIDR notation (e.g., "192.168.1.0/24")
    if range.include?('/')
      ipaddr = IPAddr.new(range)
      ipaddr.include?(IPAddr.new(ip))
    # Handle single IP
    elsif range.match?(/\A\d+\.\d+\.\d+\.\d+\z/)
      ip == range
    else
      false
    end
  rescue ArgumentError
    false
  end
end
