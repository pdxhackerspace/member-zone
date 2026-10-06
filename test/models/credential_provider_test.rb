require 'test_helper'

class CredentialProviderTest < ActiveSupport::TestCase
  setup { @member = create_member }

  test 'valid with a program from the catalog' do
    provider = CredentialProvider.new(name: 'P', script_path: credential_script('oauth.sh'))
    assert provider.valid?, provider.errors.full_messages.to_sentence
  end

  test 'requires a name and a program, and the name is unique ignoring case' do
    assert_not CredentialProvider.new(script_path: credential_script('oauth.sh')).valid?
    assert_not CredentialProvider.new(name: 'P').valid?

    create_credential_provider(name: 'Taken', describe: false)
    duplicate = CredentialProvider.new(name: 'taken', script_path: credential_script('oauth.sh'))
    assert_not duplicate.valid?
    assert duplicate.errors.of_kind?(:name, :taken)
  end

  test 'rejects a program outside the allowed directories' do
    provider = CredentialProvider.new(name: 'P', script_path: '/bin/sh')
    assert_not provider.valid?
    assert_includes provider.errors[:script_path].to_sentence, 'credential script directory'
  end

  test 'rejects a program that is not executable or does not exist' do
    assert_not CredentialProvider.new(name: 'P', script_path: credential_script('not_executable.sh')).valid?
    assert_not CredentialProvider.new(name: 'P', script_path: credential_script('nope.sh')).valid?
  end

  test 'rejects a path that climbs out of the allowed directory' do
    assert_not CredentialProvider.new(name: 'P',
                                      script_path: "#{credential_script('oauth.sh')}/../../../../../../bin/sh").valid?
    assert_not CredentialProvider.new(name: 'P', script_path: "#{CREDENTIAL_FIXTURE_DIR}/../../../../bin/sh").valid?
  end

  test 'max_per_member must be a sensible whole number' do
    [0, -1, 101, 1.5].each do |bad|
      assert_not CredentialProvider.new(name: 'P', script_path: credential_script('oauth.sh'),
                                        max_per_member: bad).valid?
    end
  end

  test 'health status must be a known one' do
    provider = create_credential_provider(describe: false)
    provider.health_status = 'sleepy'
    assert_not provider.valid?
  end

  test 'there are no member-chosen expiry or revoke-on-expiry settings' do
    columns = CredentialProvider.column_names
    %w[default_ttl_days max_ttl_days revoke_on_expiry revoke_on_inactive training_topic_id].each do |gone|
      assert_not_includes columns, gone
    end
  end

  test 'command_arguments is the program, the action, then the configured arguments' do
    provider = create_credential_provider(script_arguments: ' --verbose   --limit=5 ', describe: false)
    assert_equal [credential_script('oauth.sh'), 'issue', '--verbose', '--limit=5'], provider.command_arguments('issue')
    assert_equal [credential_script('oauth.sh'), 'health'],
                 create_credential_provider(describe: false).command_arguments(:health)
  end

  test 'environment variables are encrypted at rest and round-trip' do
    provider = create_credential_provider(env: { API_KEY: 'sup3r-s3cret-key' }, describe: false)

    raw = CredentialProvider.connection.select_value(
      "SELECT environment_variables FROM credential_providers WHERE id = #{provider.id}"
    )
    assert raw.start_with?('enc:v1:'), 'stored value must carry the encryption marker'
    assert_not_includes raw, 'sup3r-s3cret-key'
    assert_not_includes raw, 'API_KEY'

    assert_equal 'sup3r-s3cret-key', provider.reload.parsed_environment_variables['API_KEY']
  end

  test 'schema helpers read the cached describe output' do
    provider = create_credential_provider
    assert provider.schema_ready?
    assert_equal 'Client secret', provider.schema_field('client_secret')['label']
    assert_nil provider.schema_field('nope')
    assert provider.supports?('issue')
    assert provider.supports_pause?
    assert_equal 'Fixture OAuth client', provider.schema_display_name

    bare = create_credential_provider(describe: false, name: 'Bare name')
    assert_not bare.schema_ready?
    assert_equal 'Bare name', bare.schema_display_name
  end

  test 'a program without pause and resume cannot pause' do
    provider = create_credential_provider(script: 'single_key.rb')
    assert_not provider.supports_pause?
    assert_equal %w[issue revoke health], provider.schema_actions
  end

  test 'issue_denial_reason is nil for an eligible member' do
    provider = create_credential_provider
    assert_nil provider.issue_denial_reason(@member)
    assert_nil provider.self_service_denial_reason(@member)
  end

  test 'a disabled provider issues nothing' do
    provider = create_credential_provider(enabled: false)
    assert_match(/disabled/, provider.issue_denial_reason(@member))
  end

  test 'a provider that has not described itself issues nothing' do
    provider = create_credential_provider(describe: false)
    assert_match(/not reported/, provider.issue_denial_reason(@member))
  end

  test 'an unhealthy or unconfigured provider issues nothing but an unknown one may' do
    provider = create_credential_provider(health: nil)
    assert_nil provider.issue_denial_reason(@member), 'unknown health is not a reason to refuse'

    provider.record_health!('unhealthy', 'down')
    assert_match(/unavailable/, provider.issue_denial_reason(@member))

    provider.record_health!('not_configured', 'no token')
    assert_match(/unavailable/, provider.issue_denial_reason(@member))
  end

  test 'only active members are issued credentials' do
    provider = create_credential_provider
    @member.ban!
    assert_not @member.active?
    assert_match(/active members/, provider.issue_denial_reason(@member))
    assert_match(/active members/, provider.issue_denial_reason(nil))
  end

  test 'paused key access blocks issuing' do
    provider = create_credential_provider
    @member.pause_key_access!
    assert_match(/key access is paused/, provider.issue_denial_reason(@member))
  end

  test 'every required training topic must be held' do
    provider = create_credential_provider
    laser = TrainingTopic.create!(name: "Laser #{SecureRandom.hex(3)}")
    cnc = TrainingTopic.create!(name: "CNC #{SecureRandom.hex(3)}")
    provider.required_training_topics = [laser, cnc]

    assert_match(/Requires training in/, provider.issue_denial_reason(@member))
    assert_equal [cnc, laser].sort_by(&:id), provider.missing_training_topics(@member).sort_by(&:id)

    Training.create!(trainee: @member, training_topic: laser, trained_at: Time.current)
    assert_equal [cnc], provider.reload.missing_training_topics(@member)
    assert_includes provider.issue_denial_reason(@member), cnc.name
    assert_not_includes provider.issue_denial_reason(@member), laser.name

    Training.create!(trainee: @member, training_topic: cnc, trained_at: Time.current)
    assert_nil provider.reload.issue_denial_reason(@member)
  end

  test 'no required topics means no training is needed' do
    provider = create_credential_provider
    assert_empty provider.missing_training_topics(@member)
  end

  test 'the per-member limit counts pending, active and paused but not finished credentials' do
    provider = create_credential_provider(max_per_member: 2)
    create_credential(provider: provider, user: @member, status: 'revoked')
    create_credential(provider: provider, user: @member, status: 'expired')
    create_credential(provider: provider, user: @member, status: 'failed')
    assert_nil provider.issue_denial_reason(@member)

    create_credential(provider: provider, user: @member, status: 'paused')
    assert_nil provider.issue_denial_reason(@member)
    create_credential(provider: provider, user: @member, status: 'pending')
    assert_match(/Limit of 2 reached/, provider.issue_denial_reason(@member))
  end

  test 'the limit is per member' do
    provider = create_credential_provider(max_per_member: 1)
    create_credential(provider: provider, user: @member)
    assert_nil provider.issue_denial_reason(create_member)
  end

  test 'a credential being replaced does not count toward the limit' do
    provider = create_credential_provider(max_per_member: 1)
    existing = create_credential(provider: provider, user: @member)
    assert_match(/Limit/, provider.issue_denial_reason(@member))
    assert_nil provider.issue_denial_reason(@member, replacing: existing)
  end

  test 'self service adds the provider flag to the rules' do
    provider = create_credential_provider(self_service: false)
    assert_match(/issued by an administrator/, provider.self_service_denial_reason(@member))
    assert_nil provider.issue_denial_reason(@member), 'an administrator may still issue'
  end

  test 'record_health! stores status, message and timestamps' do
    provider = create_credential_provider(health: nil)
    provider.record_health!('healthy', 'fine')
    assert_equal 'healthy', provider.health_status
    assert_equal 'fine', provider.health_message
    assert_not_nil provider.last_healthy_at
    assert_not_nil provider.last_health_check_at

    healthy_at = provider.last_healthy_at
    provider.record_health!('unhealthy', 'x' * 2000)
    assert_equal 1000, provider.health_message.length
    assert_equal healthy_at, provider.reload.last_healthy_at
  end

  test 'health label and dot' do
    provider = create_credential_provider(health: nil)
    assert_equal 'muted', provider.health_dot_class
    provider.record_health!('healthy', nil)
    assert_equal 'success', provider.health_dot_class
    provider.record_health!('not_configured', nil)
    assert_equal 'danger', provider.health_dot_class
    assert_equal 'Not configured', provider.health_label
  end

  test 'available? needs enabled, a schema and not an unavailable status' do
    provider = create_credential_provider
    assert provider.available?
    provider.record_health!('unhealthy', nil)
    assert_not provider.available?
  end

  test 'needing_attention and attention_count' do
    healthy = create_credential_provider
    broken = create_credential_provider(health: 'unhealthy')
    disabled_broken = create_credential_provider(health: 'unhealthy', enabled: false)
    assert_includes CredentialProvider.needing_attention, broken
    assert_not_includes CredentialProvider.needing_attention, healthy
    assert_not_includes CredentialProvider.needing_attention, disabled_broken

    baseline = CredentialProvider.attention_count
    create_credential(provider: healthy, user: @member, status: 'revoke_failed')
    assert_equal baseline + 1, CredentialProvider.attention_count
    stuck = create_credential(provider: healthy, user: @member, status: 'pending')
    stuck.update_columns(created_at: 1.hour.ago)
    assert_equal baseline + 2, CredentialProvider.attention_count
  end

  test 'a provider with credentials cannot be destroyed' do
    provider = create_credential_provider
    create_credential(provider: provider, user: @member, status: 'revoked')
    assert_not provider.destroy
    assert_not_empty provider.errors
  end

  test 'a provider without credentials is destroyed with its runs and topic links' do
    provider = create_credential_provider
    provider.required_training_topics = [TrainingTopic.create!(name: "T #{SecureRandom.hex(3)}")]
    assert_operator provider.credential_runs.count, :>, 0

    assert_difference -> { CredentialRun.count } => -provider.credential_runs.count,
                      -> { CredentialProviderTrainingTopic.count } => -1 do
      assert provider.destroy
    end
  end

  test 'a training topic that gates a provider cannot be destroyed' do
    provider = create_credential_provider
    topic = TrainingTopic.create!(name: "Gate #{SecureRandom.hex(3)}")
    provider.required_training_topics = [topic]
    assert_not topic.destroy
  end

  test 'self_service and ordered scopes' do
    b = create_credential_provider(name: 'B provider', describe: false)
    a = create_credential_provider(name: 'A provider', describe: false, self_service: false)
    assert_equal [a, b], CredentialProvider.where(id: [a.id, b.id]).ordered.to_a
    assert_equal [b], CredentialProvider.where(id: [a.id, b.id]).self_service.to_a
  end
end
