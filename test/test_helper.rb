ENV['RAILS_ENV'] ||= 'test'
require_relative '../config/environment'
require 'rails/test_help'

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Privileges only ever reach a member through a role attached to a topic they hold, so tests
    # that need one have to build that chain. Returns the conferring topic.
    def grant_privileges(user, *privilege_keys, member_source: 'trained_in', topic: nil)
      suffix = "#{user.id}-#{SecureRandom.hex(4)}"
      topic ||= TrainingTopic.create!(name: "Privilege topic #{suffix}", offered_to_members: false)
      role = Role.create!(name: "Privilege role #{suffix}",
                          privileges: privilege_keys.map { |key| find_or_create_privilege(key) })
      TrainingTopicRole.create!(training_topic: topic, role: role, member_source: member_source)

      if member_source == 'can_train'
        TrainerCapability.find_or_create_by!(user: user, training_topic: topic)
      else
        Training.create!(trainee: user, training_topic: topic, trained_at: Time.current)
      end

      user.reset_privilege_cache!
      topic
    end

    # Fails delivery the way an unreachable mail server does in production: the exception comes back
    # out of +deliver_now+ to whoever raised the mail.
    class UnreachableServerDelivery
      attr_accessor :settings

      def initialize(settings = {})
        @settings = settings
      end

      def deliver!(_mail)
        raise SocketError, 'getaddrinfo(3): Name or service not known'
      end
    end

    ActionMailer::Base.add_delivery_method :unreachable_server_test, UnreachableServerDelivery

    def with_unreachable_mail_server
      original = ActionMailer::Base.delivery_method
      ActionMailer::Base.delivery_method = :unreachable_server_test
      yield
    ensure
      ActionMailer::Base.delivery_method = original
    end

    # Puts the app in the state the admin UI calls "email delivery is disabled": configured for
    # SMTP, with the placeholder host that an unset SMTP_ADDRESS leaves behind.
    def with_email_disabled
      config = Rails.configuration.action_mailer
      original_method = config.delivery_method
      original_settings = config.smtp_settings
      config.delivery_method = :smtp
      config.smtp_settings = { address: MailDeliveryReadiness::PLACEHOLDER_SMTP_ADDRESS }
      yield
    ensure
      config.delivery_method = original_method
      config.smtp_settings = original_settings
    end

    # Swaps Authentik::Client for a stand-in. Reading the constant first matters: Zeitwerk
    # leaves it as a pending autoload, and remove_const on a pending autoload returns nil,
    # so the restore would pin Authentik::Client to nil for the rest of the worker process.
    def with_stubbed_authentik_client(replacement)
      original = Authentik::Client
      Authentik.send(:remove_const, :Client)
      Authentik.const_set(:Client, replacement)

      begin
        yield
      ensure
        Authentik.send(:remove_const, :Client)
        Authentik.const_set(:Client, original)
      end
    end

    def find_or_create_privilege(key)
      Privilege.find_by(key: key.to_s) || Privilege.create!(
        Privilege::CATALOG.find { |entry| entry[:key] == key.to_s } || { key: key.to_s, label: key.to_s }
      )
    end

    # Sign-in helpers, shared rather than redefined per file. Individual test classes that
    # already define their own keep winning, so adopting these is incremental.
    def sign_in_as_local_account(fixture_name, password)
      account = local_accounts(fixture_name)
      post local_login_path, params: { session: { email: account.email, password: password } }
      User.find_by!(authentik_id: "local:#{account.id}")
    end

    def sign_in_as_admin
      sign_in_as_local_account(:active_admin, 'localpassword123')
    end

    def sign_in_as_plain_member
      sign_in_as_local_account(:regular_member, 'memberpassword123')
    end

    # Local password sign-in is off unless the deployment opts in, so any test that signs in
    # this way has to turn it on and put it back.
    def with_local_auth
      original = Rails.application.config.x.local_auth.enabled
      Rails.application.config.x.local_auth.enabled = true
      yield
    ensure
      Rails.application.config.x.local_auth.enabled = original
    end

    # Proves both halves of a privilege gate at once: the affordance is absent without the
    # privilege, present with it, and — when a request is supplied — the underlying action is
    # refused without it, so hiding is never the only thing protecting it.
    #
    # The grant happens between two sign-ins rather than mid-request, because
    # User#conferred_privileges is memoized per instance and the session loads its own.
    # rubocop:disable Metrics/ParameterLists
    def assert_privilege_gates(privilege, path:, selector:, request: nil, topic: nil, count: 1)
      # rubocop:enable Metrics/ParameterLists
      member = sign_in_as_plain_member

      get instance_exec(&path)
      assert_response :success, "#{privilege}: the page must still render without the privilege"
      assert_select selector, { count: 0 },
                    "#{privilege}: #{selector} must be hidden without the privilege"

      if request
        instance_exec(member, &request)
        assert_response :redirect, "#{privilege}: the action must be refused, not merely hidden"
      end

      grant_privileges(member, privilege.to_s, topic: topic)
      sign_in_as_plain_member

      get instance_exec(&path)
      assert_select selector, { count: count },
                    "#{privilege}: #{selector} must appear with the privilege"
    end
  end
end
