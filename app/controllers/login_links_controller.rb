class LoginLinksController < ApplicationController
  include RateLimitedSignIn

  before_action :require_authenticated_user!, only: %i[show regenerate]

  # Unauthenticated, and every call that names a real member sends them an email and replaces
  # their login token. Left open it is a way to flood one member's inbox, and to invalidate the
  # link they are in the middle of using by asking for another one.
  #
  # The identifier limit is the tighter of the two, since nobody legitimately needs a fourth
  # login link within the hour, and it is keyed to the account rather than the caller.
  rate_limit to: 15, within: 15.minutes, name: 'login-link-address',
             store: RateLimiting.store, with: -> { sign_in_rate_limit_exceeded }, only: :request_link
  rate_limit to: 3, within: 1.hour, name: 'login-link-identifier',
             by: -> { params[:identifier].to_s.strip.downcase.presence || 'blank' },
             store: RateLimiting.store, with: -> { sign_in_rate_limit_exceeded }, only: :request_link

  def show
    @user = current_user
  end

  def regenerate
    current_user.generate_login_token!
    redirect_to login_link_path, notice: 'Login link generated successfully.'
  end

  def request_link
    identifier = params[:identifier].to_s.strip
    if identifier.blank?
      redirect_to login_path, alert: 'Please enter your email or username.'
      return
    end

    user = User.lookup_by_email(identifier) ||
           User.find_by('LOWER(username) = ?', identifier.downcase)

    if user
      user.generate_login_token!
      MemberMailer.login_link_sent(user, login_url: login_link_authenticate_url(token: user.login_token))
                  .deliver_later
    end

    redirect_to login_path,
                notice: 'If an account matches, a login link has been sent. ' \
                        'Links can only be used once and expire shortly.'
  end

  def authenticate
    user = User.find_by(login_token: params[:token])

    if user.nil?
      redirect_to login_path, alert: 'Invalid or already-used login link.'
      return
    end

    if user.login_token_expired?
      user.clear_login_token!
      QueuedMail.enqueue('login_link_expired', user, reason: 'Login link expired')
      redirect_to login_path, alert: 'This login link has expired. Please request a new one.'
      return
    end

    user.update!(last_login_at: Time.current)
    user.clear_login_token!
    session[:user_id] = user.id
    redirect_to root_path, notice: "Welcome back, #{user.display_name}!"
  end

  private

  def require_authenticated_user!
    return if user_signed_in?

    redirect_to login_path, alert: 'Please sign in to continue.'
  end
end
