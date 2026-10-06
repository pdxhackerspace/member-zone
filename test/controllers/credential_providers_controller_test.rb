require 'test_helper'

class CredentialProvidersControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true
    @provider = create_credential_provider(name: 'Apps', env: { API_TOKEN: 'top-secret-token' })
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  def sign_in_manager
    member = sign_in_as_plain_member
    grant_privileges(member, 'credentials.manage_providers')
    sign_in_as_plain_member
  end

  def valid_params(overrides = {})
    { credential_provider: { name: 'New provider', script_path: credential_script('oauth.sh'), self_service: '1',
                             max_per_member: '3', enabled: '1' }.merge(overrides) }
  end

  # --- Access ---

  test 'only credentials.manage_providers opens the configuration' do
    sign_in_as_plain_member
    [credential_providers_path, new_credential_provider_path, credential_provider_path(@provider),
     edit_credential_provider_path(@provider)].each do |path|
      get path
      assert_response :redirect, "#{path} should be closed to a plain member"
    end

    post credential_providers_path, params: valid_params
    assert_response :redirect
    assert_nil CredentialProvider.find_by(name: 'New provider')

    patch credential_provider_path(@provider), params: { credential_provider: { name: 'Renamed' } }
    delete credential_provider_path(@provider)
    post toggle_credential_provider_path(@provider)
    post check_health_credential_provider_path(@provider)
    post refresh_schema_credential_provider_path(@provider)
    post revoke_all_credential_provider_path(@provider)

    assert_equal 'Apps', @provider.reload.name
    assert_predicate @provider, :enabled?
    assert_nil CredentialProvider.find_by(name: 'Renamed')
  end

  test 'the other credential privileges do not open the configuration' do
    member = sign_in_as_plain_member
    grant_privileges(member, 'credentials.view_all', 'credentials.issue_for_members', 'credentials.revoke')
    sign_in_as_plain_member

    get credential_providers_path
    assert_response :redirect
    post revoke_all_credential_provider_path(@provider)
    assert_response :redirect
  end

  test 'the settings hub row appears only with the privilege' do
    member = sign_in_as_plain_member
    grant_privileges(member, 'plans.manage')
    sign_in_as_plain_member
    get settings_path
    assert_response :success
    assert_select 'a[href=?]', credential_providers_path, count: 0

    grant_privileges(member, 'credentials.manage_providers')
    sign_in_as_plain_member
    get settings_path
    assert_select 'a[href=?]', credential_providers_path, minimum: 1
  end

  test 'the settings hub flags providers that need attention' do
    create_credential_provider(health: 'unhealthy')
    create_credential(provider: @provider, user: create_member, status: 'revoke_failed')
    sign_in_as_admin

    get settings_path

    assert_response :success
    assert_select 'a[href=?]', credential_providers_path do
      assert_select '.badge', text: /2 need review/
    end
  end

  test 'administrators have access' do
    sign_in_as_admin
    get credential_providers_path
    assert_response :success
  end

  # --- Index and show ---

  test 'index lists providers with program, health and live credential count' do
    create_credential(provider: @provider, user: create_member)
    sign_in_manager

    get credential_providers_path

    assert_response :success
    assert_select 'a', text: 'Apps'
    assert_select 'code', text: 'oauth.sh'
    assert_select 'td', text: /Healthy/
    assert_select 'td.num', text: '1'
  end

  test 'a disabled or administrator-only provider says so' do
    create_credential_provider(name: 'Hidden one', enabled: false, self_service: false)
    sign_in_manager

    get credential_providers_path

    assert_select 'span.badge', text: 'Disabled'
    assert_select 'div', text: /Issued by administrators only/
  end

  test 'show lists the schema, health, runs and the manage buttons' do
    sign_in_manager

    get credential_provider_path(@provider)

    assert_response :success
    assert_select 'td code', text: 'client_secret'
    assert_select 'td', text: 'First and last four characters'
    assert_select 'td', text: 'Whole value'
    assert_select 'td', text: 'describe'
    assert_select 'form[action=?]', check_health_credential_provider_path(@provider)
    assert_select 'form[action=?]', refresh_schema_credential_provider_path(@provider)
    assert_select 'form[action=?]', toggle_credential_provider_path(@provider)
    assert_select 'form[action=?]', credential_provider_path(@provider), text: /Delete/
    assert_select 'form[action=?]', revoke_all_credential_provider_path(@provider), count: 0
  end

  test 'show offers revoke all, and no delete, once there are credentials' do
    create_credential(provider: @provider, user: create_member)
    sign_in_manager

    get credential_provider_path(@provider)

    assert_select 'form[action=?]', revoke_all_credential_provider_path(@provider)
    assert_select 'form[action=?][method=post] input[name=_method][value=delete]', credential_provider_path(@provider),
                  count: 0
  end

  test 'show says when the program cannot pause' do
    provider = create_credential_provider(script: 'single_key.rb')
    sign_in_manager

    get credential_provider_path(provider)

    assert_select 'div', text: /cannot pause, so pausing a member's key access revokes/
  end

  test 'show surfaces a schema error' do
    @provider.update_columns(schema_error: 'protocol must be 1')
    sign_in_manager

    get credential_provider_path(@provider)

    assert_select '.alert-warning', text: /protocol must be 1/
  end

  test 'the pages never show the environment variable values, only their names' do
    sign_in_manager

    get credential_provider_path(@provider)
    assert_select 'dd', text: /API_TOKEN/
    assert_not_includes response.body, 'top-secret-token'

    get credential_providers_path
    assert_not_includes response.body, 'top-secret-token'

    get edit_credential_provider_path(@provider)
    assert_not_includes response.body, 'top-secret-token'
  end

  test 'a run that echoed the key shows it redacted' do
    provider = create_credential_provider(script: 'stderr_leaks_env.sh', env: { API_KEY: 'live-key-0123456789' })
    Credentials::HealthCheck.call(provider)
    sign_in_manager

    get credential_provider_path(provider)

    assert_includes response.body, '[REDACTED]'
    assert_not_includes response.body, 'live-key-0123456789'
  end

  # --- New and edit ---

  test 'new lists only the programs in the catalog' do
    sign_in_manager

    get new_credential_provider_path

    assert_response :success
    assert_select 'select[name=?] option[value=?]', 'credential_provider[script_path]', credential_script('oauth.sh')
    assert_select 'select[name=?] option[value=?]', 'credential_provider[script_path]',
                  credential_script('not_executable.sh'), count: 0
    assert_select 'select[name=?] option[value=?]', 'credential_provider[script_path]',
                  credential_script('_common.sh'), count: 0
    assert_select 'textarea[name=?]', 'credential_provider[environment_variables]'
    assert_select 'select[multiple][name=?]', 'credential_provider[required_training_topic_ids][]'
  end

  test 'edit leaves the environment textarea blank and says it is stored' do
    sign_in_manager

    get edit_credential_provider_path(@provider)

    assert_response :success
    assert_select 'textarea[name=?]', 'credential_provider[environment_variables]', text: ''
    assert_select 'textarea[placeholder*=?]', 'Leave blank to keep it'
    assert_select 'input[name=?]', 'credential_provider[clear_environment_variables]'
    assert_select '.form-text', text: /Currently set: .*API_TOKEN/
  end

  test 'edit does not offer to clear variables when there are none' do
    provider = create_credential_provider(describe: false)
    provider.update!(environment_variables: nil)
    sign_in_manager

    get edit_credential_provider_path(provider)

    assert_select 'input[name=?]', 'credential_provider[clear_environment_variables]', count: 0
  end

  # --- Create ---

  test 'create stores the provider, asks the program to describe itself and queues a health check' do
    sign_in_manager

    assert_difference -> { CredentialProvider.count } => 1 do
      assert_enqueued_with(job: Credentials::HealthCheckJob) do
        post credential_providers_path, params: valid_params(script_arguments: '--fast',
                                                             environment_variables: "A=1\nB=2")
      end
    end

    created = CredentialProvider.find_by!(name: 'New provider')
    assert_redirected_to credential_provider_path(created)
    assert_equal({ 'A' => '1', 'B' => '2' }, created.parsed_environment_variables)
    assert_equal '--fast', created.script_arguments
    assert_equal 3, created.max_per_member
    assert created.schema_ready?, 'describe must have been run synchronously'
    assert_equal 1, created.credential_runs.where(action: 'describe').count
  end

  test 'create stores required training topics' do
    topics = [TrainingTopic.create!(name: "A #{SecureRandom.hex(3)}"),
              TrainingTopic.create!(name: "B #{SecureRandom.hex(3)}")]
    sign_in_manager

    post credential_providers_path, params: valid_params(required_training_topic_ids: ['', *topics.map(&:id)])

    assert_equal topics.sort_by(&:id),
                 CredentialProvider.find_by!(name: 'New provider').required_training_topics.sort_by(&:id)
  end

  test 'create encrypts the environment at rest' do
    sign_in_manager

    post credential_providers_path, params: valid_params(environment_variables: 'API_TOKEN=plain-text-token')

    created = CredentialProvider.find_by!(name: 'New provider')
    raw = CredentialProvider.connection.select_value(
      "SELECT environment_variables FROM credential_providers WHERE id = #{created.id}"
    )
    assert raw.start_with?('enc:v1:')
    assert_not_includes raw, 'plain-text-token'
  end

  test 'create refuses a program outside the catalog' do
    sign_in_manager

    assert_no_difference -> { CredentialProvider.count } do
      post credential_providers_path, params: valid_params(script_path: '/bin/sh')
    end

    assert_response :unprocessable_content
    assert_select '.alert-danger', text: /credential script directory/
  end

  test 'create refuses a non-executable program and a traversal path' do
    sign_in_manager

    [credential_script('not_executable.sh'), "#{CREDENTIAL_FIXTURE_DIR}/../../../../../bin/sh"].each do |path|
      assert_no_difference -> { CredentialProvider.count } do
        post credential_providers_path, params: valid_params(script_path: path)
      end
      assert_response :unprocessable_content
    end
  end

  test 'create with a blank name re-renders the form without echoing the environment' do
    sign_in_manager

    post credential_providers_path, params: valid_params(name: '', environment_variables: 'API_TOKEN=typed-secret')

    assert_response :unprocessable_content
    assert_not_includes response.body, 'typed-secret'
  end

  test 'a program that cannot describe itself still saves, with the error shown' do
    sign_in_manager

    post credential_providers_path, params: valid_params(script_path: credential_script('bad_describe.sh'))

    created = CredentialProvider.find_by!(name: 'New provider')
    assert_not created.schema_ready?
    assert_match(/non-empty array/, created.schema_error)
  end

  # --- Update ---

  test 'update with a blank environment keeps the stored one and does not re-describe' do
    sign_in_manager

    assert_no_difference -> { @provider.credential_runs.where(action: 'describe').count } do
      patch credential_provider_path(@provider), params: { credential_provider: { name: 'Renamed',
                                                                                  environment_variables: '' } }
    end

    assert_redirected_to credential_provider_path(@provider)
    @provider.reload
    assert_equal 'Renamed', @provider.name
    assert_equal 'top-secret-token', @provider.parsed_environment_variables['API_TOKEN']
  end

  test 'update with new values replaces the environment and re-describes' do
    sign_in_manager

    assert_difference -> { @provider.credential_runs.where(action: 'describe').count } => 1 do
      patch credential_provider_path(@provider),
            params: { credential_provider: { environment_variables: 'API_TOKEN=new' } }
    end

    assert_equal({ 'API_TOKEN' => 'new' }, @provider.reload.parsed_environment_variables)
  end

  test 'update can clear the environment explicitly' do
    sign_in_manager

    patch credential_provider_path(@provider), params: { credential_provider: { environment_variables: '',
                                                                                clear_environment_variables: '1' } }

    assert_empty @provider.reload.parsed_environment_variables
  end

  test 'an unchecked clear box clears nothing' do
    sign_in_manager

    patch credential_provider_path(@provider), params: { credential_provider: { environment_variables: '',
                                                                                clear_environment_variables: '0' } }

    assert_equal 'top-secret-token', @provider.reload.parsed_environment_variables['API_TOKEN']
  end

  test 'changing the program resets the schema and describes the new one' do
    sign_in_manager

    patch credential_provider_path(@provider),
          params: { credential_provider: { script_path: credential_script('single_key.rb') } }

    @provider.reload
    assert_equal %w[api_key], @provider.schema_fields.pluck('key')
  end

  test 'changing to a program that cannot describe leaves no schema from the old one' do
    sign_in_manager

    patch credential_provider_path(@provider),
          params: { credential_provider: { script_path: credential_script('bad_describe.sh') } }

    @provider.reload
    assert_not @provider.schema_ready?
    assert_empty @provider.schema_fields
  end

  test 'update changes the required training and flags' do
    topic = TrainingTopic.create!(name: "T #{SecureRandom.hex(3)}")
    sign_in_manager

    patch credential_provider_path(@provider),
          params: { credential_provider: { required_training_topic_ids: [topic.id], self_service: '0',
                                           max_per_member: '9' } }

    @provider.reload
    assert_equal [topic], @provider.required_training_topics.to_a
    assert_not @provider.self_service?
    assert_equal 9, @provider.max_per_member
  end

  test 'update with invalid values re-renders' do
    sign_in_manager

    patch credential_provider_path(@provider), params: { credential_provider: { name: '' } }

    assert_response :unprocessable_content
    assert_equal 'Apps', @provider.reload.name
  end

  test 'a program that has left the catalog still shows in the picker when editing' do
    @provider.update_columns(script_path: '/opt/legacy/old.sh')
    sign_in_manager

    get edit_credential_provider_path(@provider)

    assert_select 'select[name=?] option[value=?]', 'credential_provider[script_path]', '/opt/legacy/old.sh'
  end

  # --- Destroy, toggle and the buttons ---

  test 'destroy deletes a provider with no credentials' do
    sign_in_manager

    assert_difference -> { CredentialProvider.count } => -1 do
      delete credential_provider_path(@provider)
    end
    assert_redirected_to credential_providers_path
  end

  test 'destroy refuses a provider that has issued credentials' do
    create_credential(provider: @provider, user: create_member, status: 'revoked')
    sign_in_manager

    assert_no_difference -> { CredentialProvider.count } do
      delete credential_provider_path(@provider)
    end
    assert_redirected_to credential_provider_path(@provider)
    assert_match(/Cannot delete/, flash[:alert])
  end

  test 'toggle disables, then enables and queues a health check' do
    sign_in_manager

    post toggle_credential_provider_path(@provider)
    assert_not @provider.reload.enabled?

    assert_enqueued_with(job: Credentials::HealthCheckJob, args: [@provider.id]) do
      post toggle_credential_provider_path(@provider)
    end
    assert @provider.reload.enabled?
  end

  test 'a provider whose program has left the catalog can still be disabled and edited' do
    stale = Rails.root.join('test/fixtures/files/audit-log/json_lines.sh').to_s
    @provider.update_columns(script_path: stale)
    sign_in_manager

    post toggle_credential_provider_path(@provider)
    assert_not @provider.reload.enabled?

    patch credential_provider_path(@provider),
          params: { credential_provider: { name: 'Renamed', script_path: stale } }
    assert_equal 'Renamed', @provider.reload.name
    assert_equal stale, @provider.script_path
  end

  test 'moving a provider to a program outside the catalog is still refused' do
    sign_in_manager

    outside = Rails.root.join('test/fixtures/files/audit-log/json_lines.sh').to_s
    patch credential_provider_path(@provider), params: { credential_provider: { script_path: outside } }

    assert_response :unprocessable_content
    assert_equal credential_script('oauth.sh'), @provider.reload.script_path
  end

  test 'check health runs now and reports' do
    @provider.update_columns(health_status: 'unknown')
    sign_in_manager

    post check_health_credential_provider_path(@provider)

    assert_redirected_to credential_provider_path(@provider)
    assert_match(/healthy/, flash[:notice])
    assert_equal 'healthy', @provider.reload.health_status
  end

  test 'check health reports an unhealthy provider' do
    provider = create_credential_provider(env: { UNHEALTHY: '1' })
    sign_in_manager

    post check_health_credential_provider_path(provider)

    assert_equal 'unhealthy', provider.reload.health_status
    assert_match(/unhealthy/, flash[:notice])
  end

  test 'refresh schema re-reads the program' do
    @provider.update_columns(schema: {})
    sign_in_manager

    post refresh_schema_credential_provider_path(@provider)

    assert_redirected_to credential_provider_path(@provider)
    assert_equal 'Schema refreshed.', flash[:notice]
    assert @provider.reload.schema_ready?
  end

  test 'refresh schema reports a failure' do
    @provider.update_columns(script_path: '/nonexistent/credentials/nope.sh')
    sign_in_manager

    post refresh_schema_credential_provider_path(@provider)

    assert_match(/Could not read the schema/, flash[:alert])
  end

  test 'revoke all revokes every live credential and reports' do
    a = create_credential(provider: @provider, user: create_member)
    b = create_credential(provider: @provider, user: create_member, status: 'paused')
    done = create_credential(provider: @provider, user: create_member, status: 'revoked')
    manager = sign_in_manager

    post revoke_all_credential_provider_path(@provider)

    assert_redirected_to credential_provider_path(@provider)
    assert_match(/Revoked 2 credential\(s\); 0 failed/, flash[:notice])
    assert_equal(%w[revoked revoked revoked], [a, b, done].map { |credential| credential.reload.status })
    assert_equal manager, a.reload.revoked_by
    assert_equal 'revoked_by_admin', a.revocation_reason
  end

  # --- Logging ---

  test 'environment_variables is a filtered parameter' do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)

    filtered = filter.filter('credential_provider' => { 'environment_variables' => 'API_TOKEN=x', 'name' => 'n' })

    assert_equal '[FILTERED]', filtered.dig('credential_provider', 'environment_variables')
    assert_equal 'n', filtered.dig('credential_provider', 'name')
  end

  test 'the environment never reaches the log when a provider is saved' do
    sign_in_manager
    io = StringIO.new
    Rails.logger.broadcast_to(ActiveSupport::Logger.new(io))

    post credential_providers_path, params: valid_params(environment_variables: 'API_TOKEN=very-private-value')

    assert_not_includes io.string, 'very-private-value'
  ensure
    Rails.logger.stop_broadcasting_to(Rails.logger.broadcasts.last) if Rails.logger.broadcasts.size > 1
  end
end
