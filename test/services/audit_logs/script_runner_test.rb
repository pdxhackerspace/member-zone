require 'test_helper'
require 'tmpdir'

module AuditLogs
  class ScriptRunnerTest < ActiveSupport::TestCase
    def run_script(name, timeout: 20, since: nil, **attrs)
      ScriptRunner.call(create_audit_log_source(script: name, **attrs), since: since, timeout: timeout)
    end

    test 'runs a shell program' do
      result = run_script('json_lines.sh')

      assert_predicate result, :success?
      assert_equal 2, result.stdout.lines.size
      assert_includes result.stdout, 'door opened'
    end

    test 'runs a Python program' do
      skip 'python3 is not installed here' unless system('python3', '--version', out: File::NULL, err: File::NULL)

      result = run_script('python_lines.py')

      assert_predicate result, :success?
      assert_includes result.stdout, 'python says hello'
    end

    test 'runs a Ruby program without the Rails app bundle leaking into it' do
      result = run_script('ruby_lines.rb')

      assert_predicate result, :success?
      output = JSON.parse(result.stdout.lines.first)
      assert_equal 'ruby says hello', output['message']
      assert_not_includes output['rubyopt'], 'bundler/setup'
    end

    test 'the source environment variables reach the program' do
      result = run_script('json_lines.sh', environment_variables: "AUDIT_TEST_TOKEN=hunter2\n")
      assert_includes result.stdout, 'token=hunter2'
    end

    test 'the program is told its source name and, once known, the time of the newest entry' do
      source = create_audit_log_source(script: 'since.sh', name: 'Door log')

      first = ScriptRunner.call(source, since: nil)
      assert_includes first.stdout, 'since=none source=Door log'

      later = ScriptRunner.call(source, since: Time.utc(2026, 9, 29, 10, 30))
      assert_includes later.stdout, 'since=2026-09-29T10:30:00Z'
    end

    test 'arguments are passed after the path' do
      result = run_script('since.sh', script_arguments: '--verbose --limit=5')
      assert_includes result.stdout, 'args=--verbose --limit=5'
    end

    test 'syslog settings are passed through when configured' do
      original = ENV.to_h.slice('SYSLOG_SERVER', 'SYSLOG_PORT')
      ENV['SYSLOG_SERVER'] = 'logs.example.org'
      ENV['SYSLOG_PORT'] = '514'

      env = ScriptRunner.new(create_audit_log_source, nil, 1).environment
      assert_equal 'logs.example.org', env['SYSLOG_SERVER']
      assert_equal '514', env['SYSLOG_PORT']
    ensure
      ENV.delete('SYSLOG_SERVER')
      ENV.delete('SYSLOG_PORT')
      original.each { |key, value| ENV[key] = value }
    end

    test 'a non-zero exit is a failure, and stdout and stderr are both returned' do
      result = run_script('failing.sh')

      assert_not_predicate result, :success?
      assert_equal 3, result.exit_code
      assert_includes result.stdout, 'got this far'
      assert_includes result.stderr, 'something broke'
    end

    test 'a program that never finishes is killed at the timeout with its partial output' do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = run_script('slow.sh', timeout: 1)

      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 10
      assert result.timed_out
      assert_not_predicate result, :success?
      assert_includes result.stdout, 'before the hang'
      assert_includes result.stderr, 'Timed out'
    end

    test 'a missing program raises' do
      source = create_audit_log_source(script_path: '/nonexistent/audit-log/nope.sh')
      assert_raises(Errno::ENOENT) { ScriptRunner.call(source) }
    end

    test 'a program without an executable bit raises rather than being guessed at' do
      source = create_audit_log_source(script: 'not_executable.sh')
      assert_raises(Errno::EACCES) { ScriptRunner.call(source) }
    end

    # --- Never through a shell ---

    def copy_fixture_to(directory, name)
      path = File.join(directory, name)
      FileUtils.cp(audit_log_script('json_lines.sh'), path)
      FileUtils.chmod(0o755, path)
      path
    end

    test 'a program path containing spaces is run as one path' do
      Dir.mktmpdir('audit log dir') do |directory|
        source = create_audit_log_source(script_path: copy_fixture_to(directory, 'my program.sh'))

        result = ScriptRunner.call(source)

        assert_predicate result, :success?, result.stderr
        assert_includes result.stdout, 'door opened'
      end
    end

    test 'shell metacharacters in a program path are not interpreted' do
      marker = "audit_log_shell_marker_#{SecureRandom.hex(4)}"
      Dir.mktmpdir do |directory|
        source = create_audit_log_source(script_path: copy_fixture_to(directory, "run; touch #{marker}"))

        result = ScriptRunner.call(source)

        assert_predicate result, :success?, result.stderr
        assert_not File.exist?(marker), 'the path was handed to a shell'
      end
    ensure
      FileUtils.rm_f(marker)
    end

    test 'a path with a glob or expansion character runs literally' do
      Dir.mktmpdir do |directory|
        source = create_audit_log_source(script_path: copy_fixture_to(directory, 'a$HOME*.sh'))

        assert_predicate ScriptRunner.call(source), :success?
      end
    end

    test 'a program with no arguments is still not run through a shell' do
      Dir.mktmpdir do |directory|
        source = create_audit_log_source(script_path: copy_fixture_to(directory, 'one&two.sh'), script_arguments: nil)

        assert_predicate ScriptRunner.call(source), :success?
      end
    end
  end
end
