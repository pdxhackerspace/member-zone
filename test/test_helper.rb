ENV['RAILS_ENV'] ||= 'test'
require_relative '../config/environment'
require 'rails/test_help'

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Postgres gets one database per worker for free; Redis does not, and the RFID sign-in handoff
    # is entirely Redis. Two workers sharing a database is not a theoretical problem: scans are
    # stamped in whole seconds and RfidWebhookService.claim_recent takes the newest one it can
    # find, so a scan stored by worker 2 is a perfectly good candidate for a claim made by worker
    # 1 in the same second. Pointing each worker at its own database removes the question.
    #
    # Database 0 is left for anything run outside the suite, so workers take 1 upwards. How many
    # there are to hand out is asked of the server rather than assumed: Redis ships with 16, this
    # suite runs one worker per core, and a machine with more than 15 of them wraps around and
    # puts two workers back in one database. The test container is started with enough of them
    # (see docker-compose.test.yml); the tests also use RFID values unique to each example, which
    # is the belt to this braces.
    parallelize_setup do |worker|
      ENV['REDIS_URL'] = redis_url_for_test_worker(worker)
      # The connection is memoized, and reading ENV again is the only way to pick up the new
      # database. Nothing has touched Redis this early, so there is no live connection to lose.
      RfidWebhookService.remove_instance_variable(:@redis) if RfidWebhookService.instance_variable_defined?(:@redis)
    end

    def self.redis_url_for_test_worker(worker)
      base = ENV.fetch('REDIS_URL', 'redis://localhost:6379/0')
      uri = URI.parse(base)
      uri.path = "/#{(worker % (redis_database_count(base) - 1)) + 1}"
      uri.to_s
    end

    # Falls back to the stock 16 if the server will not say, which is no worse than assuming it.
    def self.redis_database_count(url)
      @redis_database_count ||= begin
        reported = Redis.new(url: url).config(:get, 'databases')['databases'].to_i
        reported > 1 ? reported : 16
      rescue StandardError
        16
      end
    end

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Rate limit counters are not rolled back the way the database is: the store belongs to the
    # process, and most of the limits are keyed by IP — which is 127.0.0.1 for every request the
    # suite makes. Hundreds of tests sign in through sign_in_as_admin, so without this the
    # twenty-first of them is rate limited and fails for a reason that has nothing to do with what
    # it was testing. Tests that assert on a limit build their own count from this clean slate.
    setup { RateLimiting.reset! }

    # Redis is not rolled back between tests the way the database is, so anything that leaves a
    # pending scan, a claim, or a count of failed guesses behind has to clear up after itself.
    # One scan covers the scans, the claims on them, the failed-guess counts and the session
    # bindings, because every key the service writes begins this way. Matching each prefix
    # separately walked the whole keyspace once per prefix, and this runs in the setup and the
    # teardown of every RFID test.
    def reset_rfid_webhook_state!
      redis = RfidWebhookService.redis
      keys = redis.scan_each(match: "#{RfidWebhookService::REDIS_KEY_PREFIX.chomp(':')}*").to_a
      redis.del(*keys) if keys.any?
    end

    # An RFID value no other example is using, so that a scan stored here cannot be picked up by a
    # test running beside it.
    def unique_rfid
      "test-#{SecureRandom.hex(8)}"
    end

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

    # The overdue payment reminder is off by default, and the membership_lapsed email is its
    # last stage, so anything expecting a lapse notice has to switch the reminder on first.
    def enable_payment_overdue_reminder!
      ReminderSetting.seed_defaults!
      ReminderSetting.find_by!(key: 'payment_overdue').update!(enabled: true)
    end

    # Reminder cadence lives on the reminder's own settings row, which is seeded from the
    # catalog rather than from a fixture. Pass only what the test cares about.
    def set_reminder_cadence(key, **attributes)
      ReminderSetting.seed_defaults!
      setting = ReminderSetting.find_by!(key: key)
      setting.update!(attributes)
      setting
    end

    # Puts a subject partway through its sequence, the way a run that already sent would.
    def record_reminder_sent(key, subject, at: Time.current, anchor: nil, times: 1)
      anchor ||= Reminders::Registry.eligibility_for(key)&.anchor(subject)
      times.times { ReminderDelivery.record!(key, subject, anchor: anchor, at: at) }
      ReminderDelivery.state_for(key, subject)
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
