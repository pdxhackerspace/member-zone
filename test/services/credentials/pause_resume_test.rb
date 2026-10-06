require 'test_helper'

module Credentials
  class PauseResumeTest < ActiveSupport::TestCase
    setup do
      @member = create_member
      @provider = create_credential_provider
      @credential = create_credential(provider: @provider, user: @member)
    end

    test 'pausing calls the program and marks the credential paused' do
      result = Pause.call(@credential)

      assert_predicate result, :ok?
      @credential.reload
      assert_equal 'paused', @credential.status
      assert_not_nil @credential.paused_at
      input = credential_stdin('pause')
      assert_equal @credential.external_id, input['external_id']
      assert_equal 'key_access_paused', input['reason']
      assert_equal 'success', @credential.credential_runs.find_by(action: 'pause').status
    end

    test 'pausing writes a journal entry' do
      assert_difference -> { Journal.where(action: 'credential_paused', user: @member).count } => 1 do
        Pause.call(@credential, by: users(:one))
      end
    end

    test 'a failed pause leaves the credential active' do
      provider = create_credential_provider(env: { FAIL_PAUSE: '1' })
      credential = create_credential(provider: provider, user: @member)

      result = Pause.call(credential)

      assert_not_predicate result, :ok?
      assert_equal 'active', credential.reload.status
      assert_nil credential.paused_at
    end

    test 'a program that cannot pause is not asked to' do
      provider = create_credential_provider(script: 'single_key.rb')
      credential = create_credential(provider: provider, user: @member)

      result = Pause.call(credential)

      assert_not_predicate result, :ok?
      assert_match(/cannot pause/, result.error)
      assert_equal 'active', credential.reload.status
      assert_empty credential_calls
    end

    test 'only an active credential can be paused' do
      %w[paused revoked expired revoke_failed].each do |status|
        credential = create_credential(provider: @provider, user: @member, status: status)
        assert_not_predicate Pause.call(credential), :ok?, status
      end
      assert_empty credential_calls
    end

    test 'resuming calls the program and reactivates the credential' do
      @credential.update!(status: 'paused', paused_at: 1.hour.ago)

      result = Resume.call(@credential)

      assert_predicate result, :ok?
      @credential.reload
      assert_equal 'active', @credential.status
      assert_nil @credential.paused_at
      assert_equal 'key_access_resumed', credential_stdin('resume')['reason']
    end

    test 'resuming writes a journal entry' do
      @credential.update!(status: 'paused')
      assert_difference -> { Journal.where(action: 'credential_resumed', user: @member).count } => 1 do
        Resume.call(@credential)
      end
    end

    test 'a failed resume leaves the credential paused' do
      provider = create_credential_provider(env: { FAIL_RESUME: '1' })
      credential = create_credential(provider: provider, user: @member, status: 'paused', paused_at: 1.hour.ago)

      result = Resume.call(credential)

      assert_not_predicate result, :ok?
      assert_equal 'paused', credential.reload.status
      assert_not_nil credential.paused_at
    end

    test 'only a paused credential can be resumed' do
      assert_not_predicate Resume.call(@credential), :ok?
      assert_empty credential_calls
    end
  end
end
