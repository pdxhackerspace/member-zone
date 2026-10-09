require 'test_helper'

class CredentialsTaskTest < ActiveSupport::TestCase
  TASKS = %w[describe health expire expire_preview reconcile reconcile_preview revoke_member
             revoke_member_preview].freeze

  setup do
    Rails.application.load_tasks
    TASKS.each { |name| Rake::Task["credentials:#{name}"].reenable }
    @member = create_member
    @provider = create_credential_provider(name: 'Rake provider')
  end

  def invoke(name, *)
    out, = capture_io { Rake::Task["credentials:#{name}"].invoke(*) }
    out
  end

  test 'describe reads the schema by name' do
    @provider.update_columns(schema: {}, schema_fetched_at: nil)

    output = invoke('describe', 'Rake provider')

    assert_includes output, 'client_id, client_secret'
    assert_includes output, 'pause'
    assert @provider.reload.schema_ready?
  end

  test 'describe accepts an id and reports a failure' do
    @provider.update_columns(script_path: '/nonexistent/credentials/nope.sh')

    assert_includes invoke('describe', @provider.id.to_s), 'could not read the schema'
  end

  test 'describe without a provider aborts with usage' do
    assert_raises(SystemExit) { capture_io { Rake::Task['credentials:describe'].invoke } }
  end

  test 'describe with an unknown provider fails' do
    assert_raises(ActiveRecord::RecordNotFound) { capture_io { Rake::Task['credentials:describe'].invoke('nope') } }
  end

  test 'health runs the check and reports the status' do
    @provider.update_columns(health_status: 'unknown')

    output = invoke('health', 'Rake provider')

    assert_includes output, 'Rake provider: healthy: all good'
    assert_equal 'healthy', @provider.reload.health_status
  end

  test 'expire warns and expires, and reports what it did' do
    soon = create_credential(provider: @provider, user: @member, expires_at: 3.days.from_now)
    lapsed = create_credential(provider: @provider, user: @member, expires_at: 1.hour.ago)

    output = invoke('expire')

    assert_includes output, '1 to warn, 1 to expire'
    assert_not_includes output, '[DRY RUN]'
    assert_equal 'expired', lapsed.reload.status
    assert_not_nil soon.reload.expiry_warning_sent_at
  end

  test 'expire_preview changes nothing' do
    soon = create_credential(provider: @provider, user: @member, expires_at: 3.days.from_now)
    lapsed = create_credential(provider: @provider, user: @member, expires_at: 1.hour.ago)

    assert_no_difference ['QueuedMail.count', 'Journal.count'] do
      output = invoke('expire_preview')

      assert_includes output, '[DRY RUN] 1 to warn, 1 to expire'
      assert_includes output, "##{lapsed.id}"
    end
    assert_equal 'active', lapsed.reload.status
    assert_nil soon.reload.expiry_warning_sent_at
  end

  test 'reconcile syncs members and reports' do
    credential = create_credential(provider: @provider, user: @member)
    @member.update_columns(membership_state: 'banned_member', active: false)

    output = invoke('reconcile')

    assert_includes output, '1 members to sync'
    assert_equal 'revoked', credential.reload.status
  end

  test 'reconcile_preview changes nothing' do
    credential = create_credential(provider: @provider, user: @member)
    @member.update_columns(membership_state: 'banned_member', active: false)

    assert_no_difference ['QueuedMail.count', 'Journal.count', 'CredentialRun.count'] do
      output = invoke('reconcile_preview')

      assert_includes output, '[DRY RUN] 1 members to sync'
      assert_includes output, "id #{@member.id}"
    end
    assert_equal 'active', credential.reload.status
    assert_empty credential_calls
  end

  test 'revoke_member revokes every live credential of the member' do
    mine = create_credential(provider: @provider, user: @member)
    theirs = create_credential(provider: @provider, user: create_member)

    output = invoke('revoke_member', @member.id.to_s)

    assert_includes output, 'revoked 1, failed 0'
    assert_equal 'revoked', mine.reload.status
    assert_equal 'active', theirs.reload.status
  end

  test 'revoke_member_preview lists what would be revoked and changes nothing' do
    mine = create_credential(provider: @provider, user: @member, label: 'laptop')

    assert_no_difference ['QueuedMail.count', 'Journal.count', 'CredentialRun.count'] do
      output = invoke('revoke_member_preview', @member.id.to_s)

      assert_includes output, '[DRY RUN]'
      assert_includes output, 'would revoke 1'
      assert_includes output, '(laptop)'
    end
    assert_equal 'active', mine.reload.status
    assert_empty credential_calls
  end

  test 'revoke_member without a user aborts with usage' do
    assert_raises(SystemExit) { capture_io { Rake::Task['credentials:revoke_member'].invoke } }
  end
end
