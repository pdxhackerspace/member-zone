require 'test_helper'

module Credentials
  class ScriptRunnerTest < ActiveSupport::TestCase
    def run_action(action = 'health', options = {})
      input = options.delete(:input)
      timeout = options.delete(:timeout) || 20
      provider = create_credential_provider(describe: false, **options)
      ScriptRunner.call(provider, action, input: input, timeout: timeout)
    end

    test 'runs a shell program and captures stdout' do
      result = run_action('describe')

      assert_predicate result, :success?
      assert_equal 0, result.exit_code
      assert_equal 1, JSON.parse(result.stdout)['protocol']
      assert_not_nil result.duration_ms
    end

    test 'runs a Ruby program' do
      result = run_action('describe', script: 'single_key.rb')

      assert_predicate result, :success?
      assert_equal 'Fixture API key', JSON.parse(result.stdout)['name']
    end

    test 'the action is the first argument and configured arguments follow' do
      result = run_action('describe', script: 'echo_env.rb', script_arguments: '--verbose --limit=5')

      assert_equal %w[describe --verbose --limit=5], JSON.parse(result.stdout)['argv']
    end

    test 'stdin is delivered to the program' do
      payload = JSON.generate(request_id: 'abc', note: 'héllo')
      result = run_action('issue', script: 'echo_env.rb', input: payload)

      assert_equal payload.force_encoding('UTF-8'), JSON.parse(result.stdout)['stdin']
    end

    test 'a program that ignores stdin does not wedge the runner' do
      big = 'x' * 500_000
      result = run_action('describe', input: big, timeout: 10)

      assert_predicate result, :success?
    end

    test 'only allow-listed variables, the provider environment and the credential markers reach the program' do
      result = run_action('health', script: 'echo_env.rb', env: { API_KEY: 'k-123', REGION: 'eu' })
      env = JSON.parse(result.stdout)['env']

      assert_equal 'k-123', env['API_KEY']
      assert_equal 'eu', env['REGION']
      assert_equal 'health', env['CREDENTIAL_ACTION']
      assert env['CREDENTIAL_PROVIDER'].start_with?('Provider ')
      assert env.key?('PATH')
    end

    test 'nothing of the Rails process leaks into the program' do
      ENV['MEMBERZONE_TEST_LEAK'] = 'leaked'
      env = JSON.parse(run_action('health', script: 'echo_env.rb').stdout)['env']

      %w[DATABASE_URL SECRET_KEY_BASE RAILS_ENV REDIS_URL RUBYOPT BUNDLE_GEMFILE BUNDLE_BIN_PATH MEMBERZONE_TEST_LEAK
         AUTHENTIK_TOKEN AUTHENTIK_API_TOKEN].each do |name|
        assert_not env.key?(name), "#{name} must not reach a credential program"
      end
    ensure
      ENV.delete('MEMBERZONE_TEST_LEAK')
    end

    test 'the environment is exactly the allow-list plus provider variables' do
      provider = create_credential_provider(script: 'echo_env.rb', describe: false, env: { A: '1' })
      expected = ScriptRunner::PASSTHROUGH_ENV + %w[A STATE_DIR CREDENTIAL_PROVIDER CREDENTIAL_ACTION]
      assert_empty ScriptRunner.new(provider, 'health', nil, 5).environment.keys - expected
    end

    test 'syslog settings are passed through when configured' do
      ENV['SYSLOG_SERVER'] = 'logs.example.org'
      ENV['SYSLOG_PORT'] = '514'
      env = ScriptRunner.new(create_credential_provider(describe: false), 'health', nil, 1).environment

      assert_equal 'logs.example.org', env['SYSLOG_SERVER']
      assert_equal '514', env['SYSLOG_PORT']
    ensure
      ENV.delete('SYSLOG_SERVER')
      ENV.delete('SYSLOG_PORT')
    end

    test 'a provider variable overrides a passthrough one' do
      env = ScriptRunner.new(create_credential_provider(describe: false, env: { LANG: 'xx' }), 'health', nil,
                             1).environment
      assert_equal 'xx', env['LANG']
    end

    test 'a non-zero exit is a failure with stdout and stderr returned' do
      result = run_action('issue', script: 'exits_3.sh', input: '{}')

      assert_not_predicate result, :success?
      assert_equal 3, result.exit_code
      assert_includes result.stdout, 'ext-partial'
      assert_includes result.stderr, 'something went wrong'
      assert_not result.timed_out
    end

    test 'exit 2 is reported as exit 2' do
      assert_equal 2, run_action('health', script: 'not_configured.sh').exit_code
    end

    test 'a program that never finishes is killed at the timeout' do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = run_action('health', script: 'slow.sh', timeout: 1)

      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 10
      assert result.timed_out
      assert_not_predicate result, :success?
      assert_nil result.exit_code
      assert_includes result.stderr, 'Timed out'
    end

    test 'the timeout kills the whole process group, not just the program' do
      run_action('health', script: 'slow.sh', timeout: 1)

      pid = File.read(File.join(credential_state_dir, 'pid')).to_i
      assert_operator pid, :>, 0
      sleep 0.3
      assert_not process_alive?(pid), 'the background child must have been killed with the program'
    end

    test 'timeouts depend on the action' do
      assert_equal 15, ScriptRunner::TIMEOUTS['describe']
      assert_equal 15, ScriptRunner::TIMEOUTS['health']
      assert_equal 30, ScriptRunner::TIMEOUTS['issue']
      assert_equal 30, ScriptRunner::TIMEOUTS['revoke']
    end

    test 'a missing program raises ENOENT' do
      provider = CredentialProvider.new(name: 'X', script_path: '/nonexistent/credentials/nope.sh')
      assert_raises(Errno::ENOENT) { ScriptRunner.call(provider, 'health') }
    end

    test 'a program without an executable bit raises EACCES' do
      provider = CredentialProvider.new(name: 'X', script_path: credential_script('not_executable.sh'))
      assert_raises(Errno::EACCES) { ScriptRunner.call(provider, 'health') }
    end

    test 'no shell is involved, so metacharacters in the path are just characters' do
      Dir.mktmpdir('metachar') do |dir|
        tricky = File.join(dir, 'evil; touch pwned & $(touch pwned) `touch pwned` $HOME.sh')
        File.write(tricky, "#!/bin/sh\necho '{\"ok\":true}'\n")
        File.chmod(0o755, tricky)
        provider = CredentialProvider.new(name: 'X', script_path: tricky)

        Dir.chdir(dir) do
          result = ScriptRunner.call(provider, 'health')

          assert_predicate result, :success?
          assert_includes result.stdout, '"ok":true'
          assert_not File.exist?('pwned'), 'the path must never be interpreted by a shell'
        end
      end
    end

    test 'arguments with metacharacters are passed literally' do
      marker = File.join(credential_state_dir, 'pwned')
      result = run_action('health', script: 'echo_env.rb', script_arguments: "; touch #{marker} &&")

      assert_predicate result, :success?
      assert_not File.exist?(marker)
      assert_includes JSON.parse(result.stdout)['argv'], ';'
    end

    def process_alive?(pid)
      return !!Process.kill(0, pid) unless File.exist?('/proc/self/stat')

      state = File.read("/proc/#{pid}/stat")[/\) (\w)/, 1]
      !state.nil? && state != 'Z'
    rescue Errno::ENOENT, Errno::ESRCH
      false
    end
  end
end
