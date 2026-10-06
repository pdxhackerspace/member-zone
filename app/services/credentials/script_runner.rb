require 'open3'

module Credentials
  # Runs a credential provider's program for one action and returns what it printed.
  #
  # Follows AuditLogs::ScriptRunner — executed directly with no shell, its own process group
  # killed whole on timeout — and goes further on the environment: the program starts from
  # an empty one (unsetenv_others), receiving only the provider's own variables, a few names
  # it needs to function (PATH, HOME, locale, proxies, CA bundle) and CREDENTIAL_PROVIDER /
  # CREDENTIAL_ACTION. Nothing of the Rails process — DATABASE_URL, secret keys, Bundler
  # settings — reaches it.
  class ScriptRunner
    TIMEOUTS = { 'describe' => 15, 'health' => 15, 'issue' => 30, 'revoke' => 30, 'pause' => 30,
                 'resume' => 30 }.freeze

    PASSTHROUGH_ENV = %w[
      PATH HOME LANG LC_ALL TZ TMPDIR SSL_CERT_FILE SSL_CERT_DIR
      HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy SYSLOG_SERVER SYSLOG_PORT
    ].freeze

    Result = Struct.new(:stdout, :stderr, :exit_code, :timed_out, :duration_ms, keyword_init: true) do
      def success?
        !timed_out && exit_code&.zero?
      end
    end

    def self.call(provider, action, input: nil, timeout: nil)
      new(provider, action.to_s, input, timeout || TIMEOUTS.fetch(action.to_s, 30)).call
    end

    def initialize(provider, action, input, timeout)
      @provider = provider
      @action = action
      @input = input
      @timeout = timeout
    end

    def call
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      path, *args = @provider.command_arguments(@action)
      result = execute(environment, path, args)
      result.duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      result
    end

    def environment
      env = ENV.to_h.slice(*PASSTHROUGH_ENV)
      env.merge!(@provider.parsed_environment_variables)
      env['CREDENTIAL_PROVIDER'] = @provider.name
      env['CREDENTIAL_ACTION'] = @action
      env
    end

    private

    # [path, path] is the argv0 form: Ruby never hands the command to a shell, even when the
    # path contains spaces or metacharacters.
    def execute(env, path, args)
      Open3.popen3(env, [path, path], *args, unsetenv_others: true, pgroup: true) do |stdin, stdout, stderr, thread|
        writer = Thread.new { write_input(stdin) }
        out = Thread.new { stdout.read }
        err = Thread.new { stderr.read }

        finished = thread.join(@timeout)
        # Also after a clean exit: a background child left holding stdout would otherwise
        # keep the readers waiting for good.
        terminate(thread.pid)
        writer.join
        build_result(finished ? thread.value.exitstatus : nil, out.value.to_s, err.value.to_s, timed_out: !finished)
      end
    end

    def build_result(exit_code, stdout, stderr, timed_out:)
      stderr = "#{stderr}\nTimed out after #{@timeout.to_i} seconds".strip if timed_out
      Result.new(stdout: stdout, stderr: stderr, exit_code: exit_code, timed_out: timed_out)
    end

    # A program that never reads stdin must not wedge us, so a closed pipe is fine.
    def write_input(stdin)
      stdin.write(@input) if @input
    rescue Errno::EPIPE, IOError
      nil
    ensure
      begin
        stdin.close
      rescue IOError
        nil
      end
    end

    def terminate(pid)
      Process.kill('KILL', -pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end
  end
end
