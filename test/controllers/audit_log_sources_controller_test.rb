require 'test_helper'

class AuditLogSourcesControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true
    @source = create_audit_log_source(name: 'Doors', environment_variables: 'API_TOKEN=top-secret')
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  def sign_in_manager
    member = sign_in_as_plain_member
    grant_privileges(member, 'audit_logs.manage')
    sign_in_as_plain_member
  end

  def valid_params(overrides = {})
    { audit_log_source: { name: 'New source', script_path: audit_log_script('json_lines.sh'), run_interval: 'daily',
                          enabled: '1' }.merge(overrides) }
  end

  # --- Access ---

  test 'only audit_logs.manage opens the configuration' do
    sign_in_as_plain_member
    [audit_log_sources_path, new_audit_log_source_path, audit_log_source_path(@source),
     edit_audit_log_source_path(@source)].each do |path|
      get path
      assert_response :redirect, "#{path} should be closed to a plain member"
    end

    post audit_log_sources_path, params: valid_params
    assert_response :redirect
    assert_nil AuditLogSource.find_by(name: 'New source')

    delete audit_log_source_path(@source)
    post run_audit_log_source_path(@source)
    post preview_audit_log_source_path(@source)
    post toggle_audit_log_source_path(@source)
    assert_predicate @source.reload, :enabled?
    assert_equal 0, @source.audit_log_runs.count
  end

  test 'reading privileges do not open the configuration' do
    member = sign_in_as_plain_member
    grant_privileges(member, 'audit_logs.view_all', 'audit_logs.view', 'audit_logs.alerts_all', 'audit_logs.alerts')
    sign_in_as_plain_member

    get audit_log_sources_path
    assert_response :redirect
    get audit_log_source_path(@source)
    assert_response :redirect
  end

  test 'a manager sees the settings hub row and administrators keep access' do
    sign_in_manager
    get settings_path
    assert_select 'a[href=?]', audit_log_sources_path

    sign_in_as_admin
    get audit_log_sources_path
    assert_response :success
  end

  test 'the settings hub row is hidden without the privilege' do
    sign_in_as_plain_member
    get settings_path
    assert_select 'a[href=?]', audit_log_sources_path, count: 0
  end

  # --- Index / show ---

  test 'index lists sources with their program, interval and entry count' do
    create_audit_log_entry(@source)
    sign_in_manager

    get audit_log_sources_path
    assert_response :success
    assert_select 'a', text: 'Doors'
    assert_select 'code', text: audit_log_script('json_lines.sh')
    assert_select 'td', text: 'Daily'
  end

  test 'the page never shows the environment variable values, only their names' do
    sign_in_manager

    get audit_log_source_path(@source)
    assert_response :success
    assert_select 'dd', text: /API_TOKEN/
    assert_not_includes response.body, 'top-secret'

    get audit_log_sources_path
    assert_not_includes response.body, 'top-secret'
  end

  test 'show lists rules and recent runs' do
    @source.audit_log_alert_rules.create!(name: 'Bad thing', pattern: 'bad')
    @source.audit_log_runs.create!(status: 'failed', exit_code: 2, output: 'boom')
    sign_in_manager

    get audit_log_source_path(@source)
    assert_select 'td', text: 'Bad thing'
    assert_select 'code', text: %r{/bad/i}
    assert_select 'td', text: /boom/
  end

  # --- Create / update ---

  test 'new and edit render the form, environment variables included' do
    sign_in_manager

    get new_audit_log_source_path
    assert_response :success
    assert_select 'select[name=?] option', 'audit_log_source[run_interval]', count: 4

    get edit_audit_log_source_path(@source)
    assert_select 'textarea[name=?]', 'audit_log_source[environment_variables]', text: /API_TOKEN=top-secret/
  end

  test 'create stores a source' do
    sign_in_manager

    assert_difference -> { AuditLogSource.count }, 1 do
      post audit_log_sources_path, params: valid_params(script_arguments: '--fast',
                                                        environment_variables: "A=1\nB=2",
                                                        run_interval: 'every_6_hours')
    end

    created = AuditLogSource.find_by!(name: 'New source')
    assert_redirected_to audit_log_source_path(created)
    assert_equal 'every_6_hours', created.run_interval
    assert_equal({ 'A' => '1', 'B' => '2' }, created.parsed_environment_variables)
  end

  test 'create can attach a training topic' do
    topic = TrainingTopic.create!(name: "Doors #{SecureRandom.hex(3)}")
    sign_in_manager

    post audit_log_sources_path, params: valid_params(training_topic_id: topic.id)
    assert_equal topic, AuditLogSource.find_by!(name: 'New source').training_topic
  end

  test 'create rejects invalid input' do
    sign_in_manager

    assert_no_difference -> { AuditLogSource.count } do
      post audit_log_sources_path, params: valid_params(script_path: '', run_interval: 'weekly')
    end
    assert_response :unprocessable_content
    assert_select '.alert-danger'
  end

  test 'update changes a source and keeps its environment when saved back unchanged' do
    sign_in_manager

    patch audit_log_source_path(@source),
          params: { audit_log_source: { run_interval: 'hourly', environment_variables: 'API_TOKEN=top-secret' } }

    assert_redirected_to audit_log_source_path(@source)
    assert_equal 'hourly', @source.reload.run_interval
    assert_equal 'top-secret', @source.parsed_environment_variables['API_TOKEN']
  end

  test 'update rejects invalid input' do
    sign_in_manager

    patch audit_log_source_path(@source), params: { audit_log_source: { name: '' } }
    assert_response :unprocessable_content
    assert_equal 'Doors', @source.reload.name
  end

  test 'run state cannot be set through the form' do
    sign_in_manager

    patch audit_log_source_path(@source),
          params: { audit_log_source: { run_status: 'success', last_run_at: 1.year.ago, last_entry_at: 1.year.ago } }
    assert_equal 'unknown', @source.reload.run_status
    assert_nil @source.last_run_at
  end

  # --- Toggle / destroy ---

  test 'toggle disables and re-enables' do
    sign_in_manager

    post toggle_audit_log_source_path(@source)
    assert_not_predicate @source.reload, :enabled?

    post toggle_audit_log_source_path(@source)
    assert_predicate @source.reload, :enabled?
  end

  test 'a source without entries can be deleted' do
    sign_in_manager

    assert_difference -> { AuditLogSource.count }, -1 do
      delete audit_log_source_path(@source)
    end
    assert_redirected_to audit_log_sources_path
  end

  test 'a source with entries cannot be deleted' do
    create_audit_log_entry(@source)
    sign_in_manager

    assert_no_difference [-> { AuditLogSource.count }, -> { AuditLogEntry.count }] do
      delete audit_log_source_path(@source)
    end
    assert_redirected_to audit_log_source_path(@source)
    assert_match(/Disable it instead/, flash[:alert])
  end

  test 'the delete button is not offered once a source has entries' do
    sign_in_manager

    get audit_log_source_path(@source)
    delete_form = 'form[action=?] input[name=_method][value=delete]'
    assert_select delete_form, audit_log_source_path(@source), count: 1

    create_audit_log_entry(@source)
    get audit_log_source_path(@source)
    assert_select delete_form, audit_log_source_path(@source), count: 0
  end

  # --- Run now / test run ---

  test 'run queues a run' do
    sign_in_manager

    assert_enqueued_with(job: AuditLogs::RunSourceJob, args: [@source.id]) do
      post run_audit_log_source_path(@source)
    end
    assert_redirected_to audit_log_source_path(@source)
  end

  test 'run refuses a disabled source' do
    @source.update!(enabled: false)
    sign_in_manager

    assert_no_enqueued_jobs { post run_audit_log_source_path(@source) }
    assert_match(/Enable the source/, flash[:alert])
  end

  test 'a test run shows what would be stored and stores nothing' do
    source = create_audit_log_source(script: 'json_lines.sh', environment_variables: 'AUDIT_TEST_TOKEN=abc')
    sign_in_manager

    assert_no_difference [-> { AuditLogEntry.count }, -> { AuditLogRun.count }] do
      post preview_audit_log_source_path(source)
    end

    assert_response :success
    assert_select 'td', text: 'door opened'
    assert_select 'td', text: 'token=abc'
    assert_select 'td', text: 'New', count: 2
    assert_nil source.reload.last_run_at
  end

  test 'a test run flags entries that are already stored' do
    source = create_audit_log_source(script: 'json_lines.sh')
    AuditLogs::RunSource.call(source)
    sign_in_manager

    post preview_audit_log_source_path(source)
    assert_select 'td', text: 'Already stored', count: 2
  end

  test 'a test run reports a program that cannot be started' do
    source = create_audit_log_source(script_path: '/nonexistent/nope.sh')
    sign_in_manager

    post preview_audit_log_source_path(source)
    assert_redirected_to audit_log_source_path(source)
    assert_match(/Could not run/, flash[:alert])
  end

  test 'a test run shows the failure output' do
    source = create_audit_log_source(script: 'failing.sh')
    sign_in_manager

    post preview_audit_log_source_path(source)
    assert_response :success
    assert_select 'pre', text: /something broke/
  end
end
