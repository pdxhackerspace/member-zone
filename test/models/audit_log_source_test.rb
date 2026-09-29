require 'test_helper'

class AuditLogSourceTest < ActiveSupport::TestCase
  test 'requires a name, a program and a known interval' do
    source = AuditLogSource.new
    assert_not source.valid?
    assert_includes source.errors[:name], "can't be blank"
    assert_includes source.errors[:script_path], "can't be blank"

    source = AuditLogSource.new(name: 'x', script_path: '/bin/true', run_interval: 'weekly')
    assert_not source.valid?
    assert source.errors.key?(:run_interval)
  end

  test 'names are unique regardless of case' do
    create_audit_log_source(name: 'Door log')
    duplicate = AuditLogSource.new(name: 'door LOG', script_path: '/bin/true')
    assert_not duplicate.valid?
  end

  test 'offers hourly, six hourly, twelve hourly and daily intervals' do
    assert_equal %w[hourly every_6_hours every_12_hours daily], AuditLogSource::INTERVALS.keys
    assert_equal 6.hours, AuditLogSource.new(run_interval: 'every_6_hours').interval_duration
  end

  test 'environment variables are encrypted at rest and readable through the model' do
    source = create_audit_log_source(environment_variables: "API_TOKEN=s3cret\n# comment\nHOST = example.org")

    stored = AuditLogSource.connection.select_value(
      "SELECT environment_variables FROM audit_log_sources WHERE id = #{source.id}"
    )
    assert stored.start_with?('enc:v1:'), 'expected the stored value to be ciphertext'
    assert_not_includes stored, 's3cret'

    assert_equal({ 'API_TOKEN' => 's3cret', 'HOST' => 'example.org' },
                 AuditLogSource.find(source.id).parsed_environment_variables)
  end

  test 'a source that has never run is due; a recent run is not' do
    source = create_audit_log_source(run_interval: 'daily')
    assert source.due?

    source.update!(last_run_at: 1.hour.ago)
    assert_not source.due?

    source.update!(last_run_at: 25.hours.ago)
    assert source.due?
  end

  test 'a run that started a whole interval ago is due despite a few seconds of drift' do
    source = create_audit_log_source(run_interval: 'hourly')
    source.update!(last_run_at: 1.hour.ago + 30.seconds)
    assert source.due?
  end

  test 'disabled sources are never due' do
    assert_not create_audit_log_source(enabled: false).due?
  end

  test 'a source that is running is not due until the run goes stale' do
    source = create_audit_log_source(run_interval: 'hourly')
    source.update!(run_status: 'running', last_run_at: 10.minutes.ago)
    assert source.running?
    assert_not source.due?

    source.update!(last_run_at: 2.hours.ago)
    assert_not source.running?
    assert source.due?
  end

  test 'claim_run! succeeds once and refuses a second caller' do
    source = create_audit_log_source
    assert source.claim_run!
    assert_equal 'running', source.run_status

    assert_not AuditLogSource.find(source.id).claim_run!
  end

  test 'claim_run! takes over a run that went stale' do
    source = create_audit_log_source
    source.update!(run_status: 'running', last_run_at: 2.hours.ago)
    assert AuditLogSource.find(source.id).claim_run!
  end

  test 'command_arguments splits arguments on whitespace' do
    source = create_audit_log_source(script: 'since.sh', script_arguments: '--a   --b=c')
    assert_equal [audit_log_script('since.sh'), '--a', '--b=c'], source.command_arguments
  end

  test 'a source with entries cannot be destroyed' do
    source = create_audit_log_source
    create_audit_log_entry(source)

    assert_not source.destroy
    assert AuditLogSource.exists?(source.id)
    assert_predicate source.errors, :any?
  end

  test 'a source without entries can be destroyed along with its rules and runs' do
    source = create_audit_log_source
    source.audit_log_alert_rules.create!(name: 'r', pattern: 'x')
    source.audit_log_runs.create!(status: 'success')

    assert_difference -> { AuditLogAlertRule.count } => -1, -> { AuditLogRun.count } => -1 do
      assert source.destroy
    end
  end

  test 'the database itself refuses to cascade a source delete into its entries' do
    source = create_audit_log_source
    create_audit_log_entry(source)

    assert_raises(ActiveRecord::InvalidForeignKey) do
      AuditLogSource.connection.execute("DELETE FROM audit_log_sources WHERE id = #{source.id}")
    end
  end

  test 'deleting a training topic detaches sources instead of deleting them' do
    topic = TrainingTopic.create!(name: "Topic #{SecureRandom.hex(3)}")
    source = create_audit_log_source(training_topic: topic)

    topic.destroy!
    assert_nil source.reload.training_topic_id
  end

  test 'readable_by gives administrators every source' do
    admin = users(:one)
    admin.update_columns(is_admin: true)
    source = create_audit_log_source

    assert_includes AuditLogSource.readable_by(admin), source
    assert source.readable_by?(admin)
  end

  test 'readable_by gives a plain member nothing' do
    create_audit_log_source
    assert_empty AuditLogSource.readable_by(users(:two))
    assert_empty AuditLogSource.readable_by(nil)
  end

  test 'view_all reads every source' do
    reader = users(:two)
    grant_privileges(reader, 'audit_logs.view_all')
    source = create_audit_log_source

    assert_includes AuditLogSource.readable_by(reader), source
  end

  test 'a topic-scoped reader sees only the sources on their topic and its subtopics' do
    reader = users(:two)
    topic = grant_privileges(reader, 'audit_logs.view')
    child = TrainingTopic.create!(name: "Child #{SecureRandom.hex(3)}", parent: topic)
    other = TrainingTopic.create!(name: "Other #{SecureRandom.hex(3)}")

    on_topic = create_audit_log_source(training_topic: topic)
    on_child = create_audit_log_source(training_topic: child)
    on_other = create_audit_log_source(training_topic: other)
    on_nothing = create_audit_log_source

    visible = AuditLogSource.readable_by(reader)
    assert_includes visible, on_topic
    assert_includes visible, on_child
    assert_not_includes visible, on_other
    assert_not_includes visible, on_nothing

    assert on_topic.readable_by?(reader)
    assert_not on_other.readable_by?(reader)
    assert_not on_nothing.readable_by?(reader)
  end
end
