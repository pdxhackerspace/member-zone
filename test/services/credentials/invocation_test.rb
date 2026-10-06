require 'test_helper'

module Credentials
  class InvocationTest < ActiveSupport::TestCase
    SECRET = 'abcd-secret-value-wxyz'.freeze

    def invoke(action, options = {}, &)
      input = options.delete(:input)
      timeout = options.delete(:timeout)
      provider = create_credential_provider(describe: false, **options)
      [provider, Invocation.call(provider, action, input: input, timeout: timeout, &)]
    end

    test 'writes a run, runs the action and returns the block value' do
      provider, outcome = invoke('describe') { |stdout| JSON.parse(stdout)['name'] }

      assert_predicate outcome, :ok?
      assert_equal 'Fixture OAuth client', outcome.value
      run = outcome.run
      assert_equal provider, run.credential_provider
      assert_equal 'describe', run.action
      assert_equal 'success', run.status
      assert_equal 0, run.exit_code
      assert_not_nil run.duration_ms
      assert_nil run.output
      assert_equal "#{credential_script('oauth.sh')} describe", run.command_line
    end

    test 'without a block any successful exit is ok' do
      _provider, outcome = invoke('revoke')
      assert_predicate outcome, :ok?
    end

    test 'the run is linked to the credential when there is one' do
      provider = create_credential_provider
      credential = create_credential(provider: provider, user: create_member)

      outcome = Invocation.call(provider, 'revoke', credential: credential, input: '{}') { true }

      assert_equal credential, outcome.run.credential
    end

    test 'a non-zero exit fails the run and keeps stderr' do
      _provider, outcome = invoke('issue', script: 'exits_3.sh', input: '{}') { |_| flunk 'block must not run' }

      assert_not outcome.ok?
      assert_not outcome.not_configured
      assert_equal 'Exited with status 3', outcome.error
      assert_equal 'failed', outcome.run.status
      assert_equal 3, outcome.run.exit_code
      assert_includes outcome.run.output, 'something went wrong'
    end

    test 'exit 2 means not configured' do
      _provider, outcome = invoke('health', script: 'not_configured.sh')

      assert_not outcome.ok?
      assert outcome.not_configured
      assert_equal 'Not configured (exit 2)', outcome.error
      assert_includes outcome.run.output, 'API_TOKEN is not set'
    end

    test 'a timeout fails the run' do
      _provider, outcome = invoke('health', script: 'slow.sh', timeout: 1)

      assert_not outcome.ok?
      assert_match(/Timed out after 1 seconds/, outcome.error)
      assert_equal 'failed', outcome.run.status
      assert_nil outcome.run.exit_code
    end

    test 'output that fails the protocol fails the run with a message that holds no values' do
      _provider, outcome = invoke('issue', script: 'bad_json.sh', input: '{}') do |stdout|
        Protocol.issue(stdout, [{ 'key' => 'client_id' }])
      end

      assert_not outcome.ok?
      assert_equal 'Invalid issue output: output is not valid JSON', outcome.error
      assert_equal 'failed', outcome.run.status
      assert_equal 0, outcome.run.exit_code
      assert_not_includes outcome.run.output, SECRET
    end

    test 'the failing outcome still carries stdout for cleanup, but the run does not' do
      _provider, outcome = invoke('issue', script: 'missing_field.sh',
                                           input: JSON.generate(request_id: 'rid')) do |stdout|
        Protocol.issue(stdout, [{ 'key' => 'client_id' }, { 'key' => 'client_secret' }])
      end

      assert_equal 'ext-rid', Protocol.external_id_from(outcome.stdout)
      assert_not_includes outcome.run.attributes.values.join(' '), 'ext-rid'
    end

    test 'a program that cannot be run is a failed run, not an exception' do
      provider = create_credential_provider(describe: false)
      provider.update_columns(script_path: '/nonexistent/credentials/nope.sh')

      outcome = Invocation.call(provider, 'health')

      assert_not outcome.ok?
      assert_equal Invocation::NOT_IN_CATALOG, outcome.error
      assert_equal 'failed', outcome.run.status
    end

    test 'a program that has left the catalog is not run' do
      provider = create_credential_provider(describe: false)
      outside = Rails.root.join('test/fixtures/files/audit-log/json_lines.sh').to_s
      provider.update_columns(script_path: outside)

      outcome = Invocation.call(provider, 'health')

      assert_not outcome.ok?
      assert_equal Invocation::NOT_IN_CATALOG, outcome.error
      assert_empty credential_calls
    end

    test 'the provider environment values are blanked out of stderr and the error' do
      _provider, outcome = invoke('health', script: 'stderr_leaks_env.sh', env: { API_KEY: 'live-key-0123456789' })

      assert_includes outcome.run.output, 'request failed using key [REDACTED]'
      assert_not_includes outcome.run.output, 'live-key-0123456789'
      assert_not_includes outcome.error.to_s, 'live-key-0123456789'
    end

    test 'environment values are blanked out of the recorded command line' do
      _provider, outcome = invoke('health', script_arguments: '--token=live-key-0123456789',
                                            env: { API_KEY: 'live-key-0123456789' })

      assert_includes outcome.run.command_line, '--token=[REDACTED]'
      assert_not_includes outcome.run.command_line, 'live-key-0123456789'
    end

    test 'an issued secret echoed to stderr is blanked out of the run' do
      _provider, outcome = invoke('issue', script: 'echoes_secret.sh',
                                           input: JSON.generate(request_id: 'rid1234567')) do |stdout|
        Protocol.issue(stdout, [{ 'key' => 'client_id' }, { 'key' => 'client_secret' }])
      end

      assert_predicate outcome, :ok?
      assert_includes outcome.run.output, 'debug: issued secret [REDACTED]'
      assert_not_includes outcome.run.output, SECRET
      assert_not_includes outcome.run.output, 'client-rid12345'
    end

    test 'nothing the program printed on stdout is stored on the run' do
      _provider, outcome = invoke('issue', script: 'oauth.sh',
                                           input: JSON.generate(request_id: 'rid1234567')) do |stdout|
        Protocol.issue(stdout, [{ 'key' => 'client_id' }, { 'key' => 'client_secret' }])
      end

      assert_secret_not_stored(SECRET)
      assert_secret_not_stored('ext-rid1234567')
      assert_predicate outcome, :ok?
    end

    test 'other actions are not redacted word by word' do
      _provider, outcome = invoke('health', script: 'exits_3.sh')

      assert_equal 'boom', outcome.run.output.lines.last.strip
    end

    test 'output is cut to a sane length' do
      provider = create_credential_provider(describe: false)
      run = provider.credential_runs.create!(action: 'health', status: 'running')
      run.update!(output: 'x' * 10)
      assert_equal 10, run.output.length
      assert_equal 20_000, Invocation::OUTPUT_LIMIT
    end
  end
end
