require 'test_helper'

module Credentials
  class IssueTest < ActiveSupport::TestCase
    SECRET = 'abcd-secret-value-wxyz'.freeze

    setup do
      @member = create_member
      @provider = create_credential_provider
    end

    def issue(provider: @provider, user: @member, issued_by: @member, **)
      Issue.call(provider: provider, user: user, issued_by: issued_by, **)
    end

    # Runs +change+ while the provider's program is running, as another request would.
    def while_the_program_runs(change)
      original = ScriptRunner.method(:call)
      ScriptRunner.define_singleton_method(:call) do |*args, **kwargs|
        original.call(*args, **kwargs).tap { change.call }
      end
      yield
    ensure
      ScriptRunner.define_singleton_method(:call, original)
    end

    test 'issues a credential: pending first, active after, with the fields in memory only' do
      result = issue(label: 'laptop CLI', request_id: SecureRandom.uuid)

      assert_predicate result, :ok?
      assert_equal SECRET, result.fields['client_secret']
      assert_match(/\Aclient-/, result.fields['client_id'])
      credential = result.credential.reload
      assert_equal 'active', credential.status
      assert_equal @member, credential.user
      assert_equal @member, credential.issued_by
      assert_equal 'laptop CLI', credential.label
      assert_equal "ext-#{credential.request_id}", credential.external_id
      assert_not_nil credential.issued_at
      assert_nil credential.expires_at
    end

    test 'keeps only hints: first and last four of the secret, the whole non-secret value' do
      credential = issue.credential.reload

      assert_equal({ 'prefix' => 'abcd', 'suffix' => 'wxyz' }, credential.field_hints['client_secret'])
      assert_equal result_client_id(credential), credential.field_hints['client_id']['value']
      assert_not_includes credential.field_hints.to_json, 'secret-value'
    end

    def result_client_id(credential)
      "client-#{credential.request_id[0, 8]}"
    end

    test 'the secret is stored nowhere in the database' do
      result = issue(label: 'laptop')

      assert_predicate result, :ok?
      assert_secret_not_stored(SECRET)
    end

    test 'the program is told the request, the label and who the member is' do
      issue(label: 'laptop CLI')

      input = credential_stdin('issue')
      assert_match(Credential::UUID_FORMAT, input['request_id'])
      assert_equal 'laptop CLI', input['label']
      assert_equal @member.authentik_id, input['member']['uid']
      assert_equal @member.username, input['member']['username']
      assert_equal @member.full_name, input['member']['name']
      assert_equal @member.email, input['member']['email']
    end

    test 'the member uid falls back to the id when there is no Authentik id' do
      @member.update_columns(authentik_id: nil)
      issue
      assert_equal @member.id.to_s, credential_stdin('issue')['member']['uid']
    end

    test 'records an issued entry in the member journal naming who issued it' do
      admin = users(:one)

      assert_difference -> { Journal.where(action: 'credential_issued', user: @member).count } => 1 do
        issue(issued_by: admin, self_service: false)
      end

      journal = Journal.where(action: 'credential_issued', user: @member).last
      assert_equal admin, journal.actor_user
      assert_equal @provider.name, journal.changes_json.dig('credential', 'provider')
      assert_not_includes journal.changes_json.to_s, 'secret-value'
    end

    test 'logs the run against the credential' do
      credential = issue.credential

      run = credential.credential_runs.find_by(action: 'issue')
      assert_equal 'success', run.status
      assert_nil run.output
    end

    test 'stores a future expiry the program reports' do
      expiry = 45.days.from_now.utc.change(usec: 0)
      provider = create_credential_provider(env: { EXPIRES_AT: expiry.iso8601 })

      credential = issue(provider: provider).credential.reload

      assert_equal expiry, credential.expires_at
    end

    test 'a past expiry is a protocol failure and the credential is revoked' do
      provider = create_credential_provider(env: { EXPIRES_AT: 1.day.ago.utc.iso8601 })

      result = issue(provider: provider)

      assert_not_predicate result, :ok?
      assert_equal 'failed', result.credential.reload.status
      assert_equal(%w[issue revoke], credential_calls.map { |line| line.split.first })
      assert_includes result.detail, 'in the past'
    end

    test 'an unparseable expiry is a protocol failure and the credential is revoked' do
      provider = create_credential_provider(env: { EXPIRES_AT: 'next tuesday' })

      result = issue(provider: provider)

      assert_not_predicate result, :ok?
      assert_equal 'failed', result.credential.reload.status
      assert_includes credential_calls.map { |line| line.split.first }, 'revoke'
    end

    test 'a failing program leaves a failed credential, no secret and no revoke' do
      provider = create_credential_provider(env: { FAIL_ISSUE: '1' })

      result = issue(provider: provider)

      assert_not_predicate result, :ok?
      assert_nil result.fields
      assert_equal Issue::GENERIC_FAILURE, result.error
      assert_equal 'failed', result.credential.reload.status
      assert_nil result.credential.external_id
      assert_equal(%w[issue], credential_calls.map { |line| line.split.first })
      assert_equal 'failed', result.credential.credential_runs.find_by(action: 'issue').status
    end

    test 'a program that hangs leaves a failed credential, not a pending one' do
      provider = create_credential_provider(script: 'slow.sh')

      result = issue(provider: provider, timeout: 1)

      assert_not_predicate result, :ok?
      assert_equal 'failed', result.credential.reload.status
      assert_match(/Timed out/, result.credential.credential_runs.find_by(action: 'issue').output)
    end

    test 'a handle recovered from a failed exit is revoked' do
      provider = create_credential_provider(script: 'exits_3.sh')

      result = issue(provider: provider)

      assert_not_predicate result, :ok?
      assert_equal 'failed', result.credential.reload.status
      assert_equal 'ext-partial', credential_stdin('revoke')['external_id']
      assert_equal 'issue_incomplete', credential_stdin('revoke')['reason']
      assert_secret_not_stored(SECRET)
    end

    test 'when that revoke fails too the credential stays revoke_failed so it is retried' do
      provider = create_credential_provider(script: 'exits_3.sh', env: { FAIL_REVOKE: '1' })

      result = issue(provider: provider)

      credential = result.credential.reload
      assert_equal 'revoke_failed', credential.status
      assert_equal 'ext-partial', credential.external_id
      assert_equal 1, credential.revoke_attempts
      assert_equal 'issue_incomplete', credential.revocation_reason
      assert_equal 1, Credential.revoke_failed.where(id: credential.id).count
    end

    test 'a missing field is a protocol failure, and the credential it did create is revoked' do
      provider = create_credential_provider(script: 'missing_field.sh')

      result = issue(provider: provider)

      assert_not_predicate result, :ok?
      assert_includes result.detail, 'missing field client_secret'
      assert_equal 'failed', result.credential.reload.status
      assert_equal "ext-#{result.credential.request_id}", credential_stdin('revoke')['external_id']
    end

    test 'an extra field is a protocol failure, and the credential is revoked' do
      provider = create_credential_provider(script: 'extra_field.sh')

      result = issue(provider: provider)

      assert_not_predicate result, :ok?
      assert_includes result.detail, 'unexpected field'
      assert_equal 'failed', result.credential.reload.status
      assert_includes credential_calls.map { |line| line.split.first }, 'revoke'
      assert_secret_not_stored(SECRET)
    end

    test 'output that is not JSON fails without a revoke, since there is no handle' do
      provider = create_credential_provider(script: 'bad_json.sh')

      result = issue(provider: provider)

      assert_not_predicate result, :ok?
      assert_equal 'failed', result.credential.reload.status
      assert_not_includes credential_calls.map { |line| line.split.first }, 'revoke'
      assert_secret_not_stored(SECRET)
    end

    test 'a program that is not configured fails the issue' do
      provider = create_credential_provider(env: { NOT_CONFIGURED: '1' })

      result = issue(provider: provider)

      assert_not_predicate result, :ok?
      assert_equal 'failed', result.credential.reload.status
    end

    test 'a secret that is too short keeps no hint' do
      provider = create_credential_provider(script: 'short_secret.sh')

      result = issue(provider: provider)

      assert_predicate result, :ok?
      assert_equal 'short1', result.fields['client_secret']
      assert_equal({}, result.credential.reload.field_hints['client_secret'])
    end

    test 'a single-field Ruby program works too' do
      provider = create_credential_provider(script: 'single_key.rb', env: { API_KEY_VALUE: 'key_0123456789abcdef0123' })

      result = issue(provider: provider)

      assert_predicate result, :ok?
      assert_equal 'key_0123456789abcdef0123', result.fields['api_key']
      assert_equal({ 'prefix' => 'key_', 'suffix' => '0123' }, result.credential.reload.field_hints['api_key'])
    end

    test 'a member banned while the program runs is not shown the secret and the credential is revoked' do
      result = while_the_program_runs(-> { User.find(@member.id).ban! }) { issue }

      assert_not result.ok?
      assert_nil result.fields
      assert_equal 'revoked', result.credential.status
      assert_equal 'member_inactive', result.credential.revocation_reason
      assert_equal(%w[issue revoke], credential_calls.map { |line| line.split.first })
    end

    test 'a member paused while the program runs has the credential revoked, not paused' do
      result = while_the_program_runs(-> { User.find(@member.id).pause_key_access! }) { issue }

      assert_not result.ok?
      assert_nil result.fields
      assert @provider.supports_pause?
      assert_equal 'revoked', result.credential.status
      assert_equal 'key_access_paused', result.credential.revocation_reason
      assert_not_includes credential_calls.map { |line| line.split.first }, 'pause'
    end

    test 'when that revoke fails the credential stays revoke_failed for the reconcile job' do
      provider = create_credential_provider(env: { FAIL_REVOKE: '1' })
      result = while_the_program_runs(-> { User.find(@member.id).ban! }) { issue(provider: provider) }

      assert_not result.ok?
      assert_equal 'revoke_failed', result.credential.status
    end

    test 'a repeated request id is refused without issuing a second credential' do
      request_id = SecureRandom.uuid
      first = issue(request_id: request_id)
      assert_predicate first, :ok?

      assert_no_difference 'Credential.count' do
        second = issue(request_id: request_id)

        assert_not_predicate second, :ok?
        assert second.duplicate
        assert_nil second.fields
      end
      assert_equal(1, credential_calls.count { |line| line.start_with?('issue') })
    end

    test 'a repeated request id is refused even after the first one failed' do
      request_id = SecureRandom.uuid
      provider = create_credential_provider(env: { FAIL_ISSUE: '1' })
      issue(provider: provider, request_id: request_id)

      assert issue(provider: provider, request_id: request_id).duplicate
    end

    test 'a request id that is not a uuid is refused' do
      assert_no_difference 'Credential.count' do
        result = issue(request_id: 'not-a-uuid')
        assert_not_predicate result, :ok?
      end
    end

    test 'the label is trimmed, limited and may be blank' do
      assert_nil issue(label: '   ').credential.label
      assert_equal 'x' * 100, issue(label: " #{'x' * 150} ").credential.label
    end

    test 'refuses a member who is not active, without running the program' do
      @member.ban!

      assert_refused issue, /active members/
    end

    test 'refuses while key access is paused' do
      @member.pause_key_access!

      assert_refused issue, /key access is paused/
    end

    test 'refuses a member missing required training' do
      topic = TrainingTopic.create!(name: "Soldering #{SecureRandom.hex(3)}")
      @provider.required_training_topics = [topic]

      assert_refused issue, /Requires training in #{topic.name}/
    end

    test 'issues once the required training is held' do
      topic = TrainingTopic.create!(name: "Soldering #{SecureRandom.hex(3)}")
      @provider.required_training_topics = [topic]
      Training.create!(trainee: @member, training_topic: topic, trained_at: Time.current)

      assert_predicate issue, :ok?
    end

    test 'refuses once the member is at the limit and counts pending and paused rows' do
      provider = create_credential_provider(max_per_member: 2)
      create_credential(provider: provider, user: @member, status: 'paused')
      create_credential(provider: provider, user: @member, status: 'pending')

      assert_refused issue(provider: provider), /Limit of 2 reached/
    end

    test 'refuses a disabled provider' do
      assert_refused issue(provider: create_credential_provider(enabled: false)), /disabled/
    end

    test 'refuses an unhealthy provider' do
      assert_refused issue(provider: create_credential_provider(health: 'unhealthy')), /unavailable/
    end

    test 'refuses a provider that has not described itself' do
      assert_refused issue(provider: create_credential_provider(describe: false)), /not reported/
    end

    test 'a member cannot self-serve from a provider that is administrator-only' do
      provider = create_credential_provider(self_service: false)

      assert_refused issue(provider: provider), /administrator/
    end

    test 'an administrator can issue from an administrator-only provider' do
      provider = create_credential_provider(self_service: false)

      result = issue(provider: provider, issued_by: users(:one))

      assert_predicate result, :ok?
      assert_equal users(:one), result.credential.issued_by
      assert_equal @member, result.credential.user
    end

    test 'when issued by someone else self-service defaults to off, unless forced on' do
      provider = create_credential_provider(self_service: false)

      assert_predicate issue(provider: provider, issued_by: nil), :ok?
      assert_not_predicate issue(provider: provider, issued_by: users(:one), self_service: true), :ok?
    end

    test 'the limit holds for back-to-back requests' do
      provider = create_credential_provider(max_per_member: 1)

      assert_predicate issue(provider: provider), :ok?
      second = issue(provider: provider)

      assert_match(/Limit of 1/, second.error)
      assert_nil second.credential
      assert_equal(1, credential_calls.count { |line| line.start_with?('issue') })
    end

    def assert_refused(result, pattern)
      assert_not_predicate result, :ok?
      assert_match pattern, result.error
      assert_nil result.fields
      assert_nil result.credential, 'a refused request must not leave a credential behind'
      assert_empty credential_calls, 'a refused request must not run the program'
    end
  end
end
