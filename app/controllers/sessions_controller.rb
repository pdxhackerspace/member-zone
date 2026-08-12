class SessionsController < ApplicationController
  # OmniAuth callback: the browser POSTs to /auth/:provider/callback after the
  # OAuth redirect. Rails CSRF tokens do not apply here; OmniAuth validates its
  # own state parameter to prevent CSRF on the OAuth flow.
  # codeql[rb/csrf-protection-disabled]: OmniAuth OIDC callback; CSRF covered by OmniAuth state.
  skip_before_action :verify_authenticity_token, only: :create

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
    redirect_to rfid_wait_path
  end

  def rfid_wait
    if session[:waiting_for_keyfob].blank?
      redirect_to login_path, alert: 'No keyfob session found. Please try again.'
      return
    end

    # Check if any webhook data is available (created after session started)
    session_start = Time.zone.at(session[:waiting_for_keyfob])
    webhook_data = RfidWebhookService.find_recent(session_start)

    return if webhook_data.blank?

    # Store the RFID from webhook in session for verification
    session[:pending_rfid] = webhook_data[:rfid]
    redirect_to rfid_verify_path
    nil
  end

  def rfid_verify
    rfid = session[:pending_rfid]
    if rfid.blank?
      redirect_to rfid_wait_path, alert: 'Waiting for keyfob scan. Please try again.'
      return
    end

    # Verify webhook data is still available
    @webhook_data = RfidWebhookService.retrieve(rfid)
    if @webhook_data.blank?
      redirect_to rfid_wait_path, alert: 'Waiting for keyfob scan. Please try again.'
      return
    end

    @reader_name = @webhook_data[:reader_name]
  end

  def rfid_check_webhook
    if session[:waiting_for_keyfob].blank?
      render json: { status: 'no_session' }, status: :ok
      return
    end

    session_start = Time.zone.at(session[:waiting_for_keyfob])
    webhook_data = RfidWebhookService.find_recent(session_start)

    if webhook_data.present?
      # Store the RFID from webhook in session
      session[:pending_rfid] = webhook_data[:rfid]
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

    # Verify the pin
    if RfidWebhookService.verify_and_consume(rfid, pin)
      # Pin is correct, log in the user
      user = find_user_by_rfid(rfid)
      if user
        session.delete(:pending_rfid)
        session.delete(:waiting_for_keyfob)
        user.update!(last_login_at: Time.current)
        session[:user_id] = user.id
        redirect_to root_path, notice: "Signed in via keyfob as #{user.display_name}."
      else
        redirect_to login_path, alert: 'Member not found. Please try again.'
      end
    else
      redirect_to rfid_verify_path, alert: 'Invalid code. Please try again.'
    end
  end

  def failure
    redirect_to root_path, alert: params[:message] || 'Authentication failed.'
  end

  private

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
