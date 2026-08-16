class ApplicationController < ActionController::Base
  include Pagy::Method
  include MemberVisibility

  protect_from_forgery with: :exception

  add_flash_types :success, :info

  helper_method :current_user, :user_signed_in?, :local_auth_enabled?, :authentik_enabled?,
                :current_user_admin?, :true_user_admin?, :impersonating?, :true_user, :can?,
                :can_for_any_topic?

  private

  def current_user
    return @current_user if defined?(@current_user)

    # The impersonated account when impersonation is in effect — see #impersonating?, which
    # lapses if the real account is no longer an administrator.
    @current_user = if impersonating?
                      User.find_by(id: session[:impersonated_user_id])
                    else
                      User.find_by(id: session[:user_id])
                    end
  end

  # The actual logged-in admin (even when impersonating)
  def true_user
    return @true_user if defined?(@true_user)

    @true_user = User.find_by(id: session[:user_id])
  end

  before_action :clear_stale_impersonation
  before_action do
    Current.user = current_user
    Current.true_user = true_user
  end

  def user_signed_in?
    current_user.present?
  end

  # Impersonation is only in effect while the real account is still an administrator.
  #
  # This is checked on every request, not just when impersonation starts, because
  # authorization resolves against the impersonated account. An administrator whose admin
  # flag is revoked mid-session would otherwise be left holding the target's privileges —
  # a session that gained authority instead of shedding it. Dropping impersonation the
  # moment the real account stops being an administrator keeps the substitution
  # subtractive, which is the property everything else rests on.
  def impersonating?
    session[:impersonated_user_id].present? && true_user&.is_admin?
  end

  def clear_stale_impersonation
    return if session[:impersonated_user_id].blank?
    return if true_user&.is_admin?

    session.delete(:impersonated_user_id)
  end

  def require_authenticated_user!
    return if user_signed_in?

    redirect_to login_path, alert: 'Please sign in to continue.'
  end

  def local_auth_enabled?
    LocalAuthConfig.enabled?
  end

  def authentik_enabled?
    AuthentikConfig.enabled_for_login?
  end

  def current_user_admin?
    current_user&.is_admin?
  end

  # The real signed-in account, ignoring impersonation. Authorization does not use this —
  # see the note on #can? — and ImpersonationsController is the only place that should.
  def true_user_admin?
    true_user&.is_admin?
  end

  def require_admin!
    return if current_user_admin?

    if current_user
      redirect_to user_path(current_user), alert: 'You do not have access to that section.'
    else
      redirect_to login_path, alert: 'Admin access is required to proceed.'
    end
  end

  # Authorization resolves against the impersonated account, because the point of
  # impersonation is to exercise the UI *and the logic* a role holder gets. Resolving
  # against the real account would defeat that: every gate would pass and an admin would
  # see their own buttons on someone else's page.
  #
  # This is safe because only an is_admin? account may impersonate, and admins hold every
  # privilege — so substituting the impersonated user can only ever subtract. Two things
  # keep that true and are covered by tests in
  # test/controllers/impersonation_privileges_test.rb:
  #
  #   1. ImpersonationsController guards create AND destroy against true_user, so the way
  #      back out never depends on what the impersonated member can do.
  #   2. Nothing may confer the ability to impersonate on a non-admin. A non-admin who
  #      could impersonate an admin would gain everything rather than lose something.
  def can?(privilege, topic: nil)
    current_user&.can?(privilege, topic: topic) || false
  end

  # The "does this hold for any topic at all" form, for navigation and index links where
  # no particular topic is in hand yet.
  def can_for_any_topic?(privilege)
    current_user&.can_for_any_topic?(privilege) || false
  end

  def require_privilege!(privilege, topic: nil)
    return if can?(privilege, topic: topic)

    if current_user
      redirect_to user_path(current_user), alert: 'You do not have access to that section.'
    else
      redirect_to login_path, alert: 'Please sign in to continue.'
    end
  end

  # A few pages are reachable by more than one route through the catalog — a cash payment
  # belongs to whoever records it, but anyone who can see payments at all can read it. The
  # denial names the first key, which is the one to grant if a holder is unsure why.
  def require_any_privilege!(*privileges)
    return if privileges.any? { |privilege| can?(privilege) }

    require_privilege!(privileges.first)
  end
end
