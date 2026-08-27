require 'test_helper'

# A guard against the class of hole that let MembershipPlansController#new exist with no
# filter covering it: every routed action must be behind authentication, an admin check, or
# a privilege check, or be named here as deliberately public.
#
# When this fails, the fix is almost always to add a before_action — not to add the action
# to the allowlist. Adding to the allowlist is a decision to serve that action to anyone on
# the internet, so it wants the same scrutiny as any other public endpoint.
class PrivilegeCoverageTest < ActiveSupport::TestCase
  # Engine and framework controllers this application does not own.
  FOREIGN_CONTROLLERS = %w[active_storage action_mailbox rails/ turbo/].freeze

  # Deliberately reachable without signing in.
  PUBLIC_ACTIONS = {
    'sessions' => %w[new create create_local create_rfid failure destroy rfid_wait rfid_verify
                     rfid_check_webhook rfid_submit_pin],
    'pages' => %w[apply],
    'invite' => %w[show accept accepted],
    'application_verifications' => %w[gate send_verification verify_email status check_email
                                      code_of_conduct_pdf],
    'applicant_notification_opt_outs' => %w[show create],
    # The public application wizard. Its admin surface lives behind
    # MembershipApplicationPrivileges and is covered below.
    'membership_applications' => %w[start page save_page submit_application confirmation],
    'login_links' => %w[request_link authenticate],
    'slack_account_links' => %w[new callback],
    # Signature/allowlist verified inside the action rather than by a filter.
    'webhooks' => %w[receive]
  }.freeze

  FILTER_NAMES = %w[require_authenticated_user! require_admin! require_privilege!
                    require_true_admin!].freeze

  # Filters that decide *who* may act, as opposed to merely that someone is signed in.
  AUTHORIZATION_FILTERS = %w[require_admin! require_privilege! require_true_admin!].freeze

  # Both forms of privilege check, for the lambda filters that are the usual shape.
  PRIVILEGE_CALLS = %w[require_privilege! require_any_privilege!].freeze

  # Controllers where being signed in is the whole rule, because access follows from the
  # record rather than from a privilege: your own profile, your own messages, the training
  # catalogue offered to every member. Everything else must name an authority.
  #
  # Adding a controller here is a decision to serve it to any signed-in member. Converting
  # one off AdminController without a privilege filter would otherwise land it here
  # silently, which is exactly the mistake this catches.
  MEMBER_FACING_CONTROLLERS = %w[
    users messages profile_setup member_parking_permits user_links search
    training_catalog training_requests documents rag membership_plans trainings
    training_topics training_topic_links settings login_links notification_preferences
  ].freeze

  test 'every routed action is authenticated, admin gated, or privilege gated' do
    unguarded = routed_actions.reject { |controller, action| guarded?(controller, action) }

    assert_empty unguarded.map { |controller, action| "#{controller}##{action}" }.sort,
                 'these actions are reachable with no authentication or authorization filter'
  end

  # Being signed in is not authorization. A controller moved off AdminController without a
  # privilege filter would still satisfy the test above, because require_authenticated_user!
  # comes along with AuthenticatedController — this is the assertion that notices.
  test 'privileged actions name an authority rather than only requiring a session' do
    unauthorized = routed_actions.reject do |controller, action|
      PUBLIC_ACTIONS[controller]&.include?(action) ||
        MEMBER_FACING_CONTROLLERS.include?(controller) ||
        authorized?(controller, action)
    end

    assert_empty unauthorized.map { |controller, action| "#{controller}##{action}" }.sort,
                 'these actions are reachable by any signed-in member with no admin or privilege check'
  end

  test 'the public allowlist only names actions that actually exist' do
    stale = PUBLIC_ACTIONS.flat_map do |controller, actions|
      routed = routed_actions.select { |name, _| name == controller }.map(&:last)
      (actions - routed).map { |action| "#{controller}##{action}" }
    end

    assert_empty stale, 'the allowlist names routes that are gone; drop them so it stays honest'
  end

  private

  def routed_actions
    @routed_actions ||= Rails.application.routes.routes.filter_map do |route|
      controller = route.defaults[:controller]
      action = route.defaults[:action]
      next if controller.blank? || action.blank?
      next if controller.start_with?(*FOREIGN_CONTROLLERS)
      next unless controller_class(controller)

      [controller, action]
    end.uniq
  end

  def authorized?(controller, action)
    klass = controller_class(controller)
    return false unless klass
    return true unless klass.action_methods.include?(action) || klass.method_defined?(action.to_sym, false)

    callbacks_for(klass).any? { |callback| decides_authority?(callback) && covers?(callback, action) }
  end

  # A named admin filter, or an inline lambda calling require_privilege!.
  def decides_authority?(callback)
    name = callback.filter
    return AUTHORIZATION_FILTERS.include?(name.to_s) if name.is_a?(Symbol)

    name.respond_to?(:source_location) && lambda_calls_privilege?(name)
  end

  def guarded?(controller, action)
    return true if PUBLIC_ACTIONS[controller]&.include?(action)

    klass = controller_class(controller)
    return false unless klass
    # An action with no method and no template is not reachable in a meaningful sense.
    return true unless klass.action_methods.include?(action) || klass.method_defined?(action.to_sym, false)

    callbacks_for(klass).any? { |callback| covers?(callback, action) }
  end

  def callbacks_for(klass)
    klass._process_action_callbacks.select { |callback| callback.kind == :before }
  end

  # A filter covers an action when it is one of the authorization filters (by name, or a
  # lambda that calls require_privilege!) and its :only/:except allow that action.
  def covers?(callback, action)
    return false unless authorization_filter?(callback)

    only = Array(callback.instance_variable_get(:@if)).join(' ')
    unless_clause = Array(callback.instance_variable_get(:@unless)).join(' ')

    return false if only.include?('action_name') && only.exclude?("\"#{action}\"")
    return false if unless_clause.include?('action_name') && unless_clause.include?("\"#{action}\"")

    true
  end

  def authorization_filter?(callback)
    name = callback.filter
    return FILTER_NAMES.include?(name.to_s) if name.is_a?(Symbol)

    # Inline lambdas: `before_action -> { require_privilege!(:'plans.manage') }`
    name.respond_to?(:source_location) && lambda_calls_privilege?(name)
  end

  def lambda_calls_privilege?(callable)
    file, line = callable.source_location
    return false unless file && File.exist?(file)

    source = File.readlines(file)[line - 1].to_s
    PRIVILEGE_CALLS.any? { |call| source.include?(call) }
  rescue StandardError
    false
  end

  def controller_class(controller)
    "#{controller}_controller".camelize.safe_constantize
  end
end
