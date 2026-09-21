class SessionsController < ApplicationController
  include RateLimitedSignIn

  # OmniAuth callback: the browser POSTs to /auth/:provider/callback after the
  # OAuth redirect. Rails CSRF tokens do not apply here; OmniAuth validates its
  # own state parameter to prevent CSRF on the OAuth flow.
  # codeql[rb/csrf-protection-disabled]: OmniAuth OIDC callback; CSRF covered by OmniAuth state.
  skip_before_action :verify_authenticity_token, only: :create

  WAITING_FOR_SCAN = 'Waiting for keyfob scan. Please try again.'.freeze
  SCAN_UNAVAILABLE = 'That keyfob scan is no longer available. Please scan your keyfob again.'.freeze

  # Password sign-in, limited twice. The address limit is the blunt one; the account limit is
  # what a botnet spreading itself over many addresses cannot avoid, because every attempt it
  # makes against one member lands on the same counter.
  rate_limit to: 20, within: 5.minutes, name: 'local-login-address',
             store: RateLimiting.store, with: -> { sign_in_rate_limit_exceeded }, only: :create_local
  rate_limit to: 10, within: 5.minutes, name: 'local-login-account',
             by: -> { submitted_email_for_rate_limit }, store: RateLimiting.store,
             with: -> { sign_in_rate_limit_exceeded }, only: :create_local

  # PIN entry. The per-scan attempt counter in RfidWebhookService is the real limit — five wrong
  # codes and the scan is gone. This is only a ceiling on how fast a script can cycle through
  # scans, set high enough that a queue of members mistyping at a kiosk never reaches it.
  rate_limit to: 60, within: 5.minutes, name: 'rfid-pin',
             store: RateLimiting.store, with: -> { sign_in_rate_limit_exceeded }, only: :rfid_submit_pin

  # The wait page polls this every two seconds, so a single member accounts for 30 requests a
  # minute and a shared address multiplies that. Ten simultaneous waiters fit under this.
  rate_limit to: 300, within: 1.minute, name: 'rfid-poll',
             store: RateLimiting.store, with: -> { json_rate_limit_exceeded }, only: :rfid_check_webhook

  def new
    return if authentik_enabled? || local_auth_enabled?

    render plain: 'No authentication methods are configured.', status: :service_unavailable
  end

  def create
    auth = request.env['omniauth.auth']
    user = upsert_user_from_auth(auth)
    user.update!(last_login_at: Time.current)
    session[:user_id] = user.id

    redirect_to root_path, notice: "Welcome back, #{user.display_name}!"
  rescue StandardError => e
    Rails.logger.error("Authentik sign-in failed: #{e.class} #{e.message}")
    # A member who cannot get in sees "please try again" and usually does not report it, so
    # without this an outage in the identity provider is invisible until someone complains.
    ErrorReporting.report(e, context: { stage: 'authentik_oidc_callback' })
    redirect_to root_path, alert: 'Unable to sign you in. Please try again.'
  end

  def create_local
    unless local_auth_enabled?
      redirect_to login_path, alert: 'Local authentication is disabled.'
      return
    end

    account = find_local_account(session_params[:email])
    if account&.active? && account.authenticate(session_params[:password])
      account.touch(:last_signed_in_at)
      user = sync_local_account(account)
      user.update!(last_login_at: Time.current)
      session[:user_id] = user.id
      redirect_to root_path, notice: "Signed in locally as #{user.display_name}."
    else
      LocalAuth::UnreadableAccounts.warn_if_any if account.nil?
      # Rendered beside the sign-in form rather than as a page-level flash, which
      # lands far above the form and reads as no response at all.
      @login_error = 'Invalid email or password.'
      render :new, status: :unprocessable_content
    end
  end

  def destroy
    reset_session
    redirect_to root_path, notice: 'Signed out successfully.'
  end

  def create_rfid
    # Store session timestamp to match with webhook data
    session[:waiting_for_keyfob] = Time.current.to_i
    # Names this browser so that the scan it picks up belongs to it alone. Without this, every
    # browser sitting on the login page saw the next scan made at the door, and whichever one
    # polled first got to guess at that member's PIN.
    session[:rfid_claim_token] = SecureRandom.urlsafe_base64(24)
    redirect_to rfid_wait_path
  end

  def rfid_wait
    if session[:waiting_for_keyfob].blank?
      redirect_to login_path, alert: 'No keyfob session found. Please try again.'
      return
    end

    scan = claim_pending_scan
    return if scan.blank?

    session[:pending_rfid] = scan[:rfid]
    redirect_to rfid_verify_path
  end

  def rfid_verify
    rfid = session[:pending_rfid]
    if rfid.blank?
      redirect_to rfid_wait_path, alert: WAITING_FOR_SCAN
      return
    end

    # The claim is checked against Redis rather than taken on the session's word, so a scan that
    # has since expired does not present a PIN box that cannot succeed.
    unless RfidWebhookService.claimed_by?(rfid, session[:rfid_claim_token])
      session.delete(:pending_rfid)
      redirect_to rfid_wait_path, alert: WAITING_FOR_SCAN
      return
    end

    @webhook_data = RfidWebhookService.retrieve(rfid)
    if @webhook_data.blank?
      redirect_to rfid_wait_path, alert: WAITING_FOR_SCAN
      return
    end

    @reader_name = @webhook_data[:reader_name]
    @attempts_remaining = RfidWebhookService::MAX_PIN_ATTEMPTS - RfidWebhookService.failed_attempts(rfid)
  end

  def rfid_check_webhook
    if session[:waiting_for_keyfob].blank?
      render json: { status: 'no_session' }, status: :ok
      return
    end

    scan = claim_pending_scan

    if scan.present?
      session[:pending_rfid] = scan[:rfid]
      render json: { status: 'ready' }, status: :ok
    else
      render json: { status: 'waiting' }, status: :ok
    end
  end

  def rfid_submit_pin
    rfid = session[:pending_rfid]
    pin = params[:pin] || params[:rfid]&.dig(:pin)

    if rfid.blank?
      redirect_to login_path, alert: 'No keyfob session found. Please try again.'
      return
    end

    if pin.blank?
      redirect_to rfid_verify_path, alert: 'Please enter the 4-digit code.'
      return
    end

    # Re-checked on submit as well as on render: the scan may have expired, or been discarded
    # after someone else exhausted its attempts, between the page loading and the PIN arriving.
    unless RfidWebhookService.claimed_by?(rfid, session[:rfid_claim_token])
      reset_rfid_sign_in
      redirect_to login_path, alert: SCAN_UNAVAILABLE
      return
    end

    resolve_pin_submission(rfid, pin)
  end

  def failure
    redirect_to root_path, alert: params[:message] || 'Authentication failed.'
  end

  private

  # Claims the newest scan made since this browser started waiting, if any is still going spare.
  def claim_pending_scan
    RfidWebhookService.claim_recent(
      Time.zone.at(session[:waiting_for_keyfob]),
      session[:rfid_claim_token]
    )
  end

  def resolve_pin_submission(rfid, pin)
    case RfidWebhookService.verify_and_consume(rfid, pin)
    when :verified
      complete_rfid_sign_in(rfid)
    when :invalid_pin
      redirect_to rfid_verify_path, alert: 'Invalid code. Please try again.'
    when :too_many_attempts
      # The scan is gone now, so there is nothing to return to; say so plainly rather than
      # bouncing back to a PIN box that would refuse every code.
      Rails.logger.warn("RFID sign-in refused after #{RfidWebhookService::MAX_PIN_ATTEMPTS} wrong codes " \
                        "from #{request.remote_ip}")
      reset_rfid_sign_in
      redirect_to login_path, alert: 'Too many incorrect codes. Please scan your keyfob again.'
    else
      reset_rfid_sign_in
      redirect_to login_path, alert: SCAN_UNAVAILABLE
    end
  end

  def complete_rfid_sign_in(rfid)
    user = find_user_by_rfid(rfid)
    reset_rfid_sign_in

    unless user
      redirect_to login_path, alert: 'Member not found. Please try again.'
      return
    end

    user.update!(last_login_at: Time.current)
    session[:user_id] = user.id
    redirect_to root_path, notice: "Signed in via keyfob as #{user.display_name}."
  end

  def reset_rfid_sign_in
    session.delete(:pending_rfid)
    session.delete(:waiting_for_keyfob)
    session.delete(:rfid_claim_token)
  end

  def upsert_user_from_auth(auth)
    payload = auth.respond_to?(:deep_symbolize_keys) ? auth.deep_symbolize_keys : auth.to_h.deep_symbolize_keys
    info = payload.fetch(:info, {})
    extra_hash = payload.fetch(:extra, {})
    extra = extra_hash.fetch(:raw_info, {})

    authentik_id = payload[:uid].to_s
    email = info[:email] || extra[:email]
    username = info[:nickname] || info[:preferred_username] || extra[:username]
    full_name = info[:name] || build_full_name(info, extra)

    # Extract admin status from Authentik
    is_admin = extract_admin_status(info, extra)

    Rails.logger.info("Authentik login: uid=#{authentik_id.inspect} email=#{email.inspect} admin=#{is_admin.inspect}")

    # First, try to find by authentik_id
    user = User.find_by(authentik_id: authentik_id) if authentik_id.present?

    # If not found and we have an email, try to find by email
    if user.nil? && email.present?
      normalized_email = email.to_s.strip.downcase
      user = User.lookup_by_email(normalized_email) if normalized_email.present?
    end

    # If still not found, initialize a new user
    user ||= User.new

    # Set authentik_id if it's not already set
    user.authentik_id = authentik_id if authentik_id.present? && user.authentik_id.blank?

    # Merge in email only if blank (don't overwrite existing email)
    user.email = email if user.email.blank? && email.present?

    # Merge in full_name only if blank (don't overwrite existing name)
    user.full_name = full_name if user.full_name.blank? && full_name.present?

    # Merge in username from Authentik
    user.username = username if username.present?

    # Update admin status from Authentik (only if we got a value from Authentik)
    user.is_admin = is_admin unless is_admin.nil?

    # For service accounts, explicitly activate on login
    # For non-service accounts, active is computed by the before_save callback
    user.active = true if user.service_account?
    user.last_synced_at = Time.current

    user.save!
    user
  end

  def extract_admin_status(info, extra)
    # Check for explicit admin claim (boolean or string)
    # This should be set by an Authentik property mapping that checks group membership
    admin_claim = info[:is_admin] || info[:admin] || extra[:is_admin] || extra[:admin]

    if admin_claim.present?
      # Handle boolean, string "true"/"false", or "1"/"0"
      return true if admin_claim == true || admin_claim.to_s.downcase.in?(%w[true 1 yes])
      return false if admin_claim == false || admin_claim.to_s.downcase.in?(%w[false 0 no])
    end

    nil # Return nil if no admin status found (don't update the field)
  end

  def sync_local_account(account)
    local_authentik_id = "local:#{account.id}"
    user = User.find_by(authentik_id: local_authentik_id)
    user = User.lookup_by_email(account.email) if user.nil? && account.email.present?
    user ||= User.new

    user.assign_attributes(
      authentik_id: local_authentik_id,
      email: account.email,
      full_name: account.full_name,
      active: account.active,
      last_synced_at: Time.current,
      is_admin: account.admin?
    )
    user.save!
    user
  end

  def session_params
    params.expect(session: %i[email password])
  end

  def rfid_params
    params.expect(rfid: [:token])
  end

  def rfid_token
    rfid_params[:token]
  rescue ActionController::ParameterMissing
    nil
  end

  def find_local_account(email)
    normalized_email = email.to_s.strip.downcase
    return if normalized_email.blank?

    LocalAccount.by_email(normalized_email).first
  end

  def build_full_name(info, extra)
    parts = [
      info[:first_name],
      info[:last_name],
      extra[:first_name],
      extra[:last_name]
    ].compact_blank

    parts.presence&.join(' ')
  end

  def find_user_by_rfid(value)
    normalized = RfidNormalizer.call(value)&.downcase
    return if normalized.blank?

    # Search in the rfids table
    rfid_record = Rfid.where('LOWER(rfid) = ?', normalized).joins(:user).where(users: { active: true }).first
    rfid_record&.user
  end
end
