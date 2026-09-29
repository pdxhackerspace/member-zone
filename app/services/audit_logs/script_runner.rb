require 'open3'

module AuditLogs
  # Runs an audit log program and returns what it printed. Like the access controller
  # scripts, the program is executed directly, so it needs an executable bit and a shebang;
  # that is what lets shell, Python and Ruby programs all work.
  #
  # Two things differ from the access controller jobs. The Rails app's Bundler settings are
  # cleared, or a Ruby program would inherit BUNDLE_GEMFILE and RUBYOPT and load this app's
  # gems instead of its own; and a program that never returns is killed after TIMEOUT rather
  # than holding a Sidekiq thread for good.
  class ScriptRunner
    TIMEOUT = 10.minutes

    Result = Struct.new(:stdout, :stderr, :exit_code, :timed_out, keyword_init: true) do
      def success?
        return false if timed_out || exit_code.nil?

        exit_code.zero?
      end
    end

    def self.call(source, since: nil, timeout: TIMEOUT)
      new(source, since, timeout).call
    end

    def initialize(source, since, timeout)
      @source = source
      @since = since
      @timeout = timeout
    end

    def call
      Bundler.with_unbundled_env { execute(environment, @source.command_arguments) }
    end

    def environment
      env = @source.parsed_environment_variables
      env['AUDIT_LOG_SOURCE'] = @source.name
      env['AUDIT_LOG_SINCE'] = @since.utc.iso8601 if @since
      %w[SYSLOG_SERVER SYSLOG_PORT].each { |key| env[key] = ENV[key] if ENV[key].present? }
      env
    end

    private

    def execute(env, command)
      Open3.popen3(env, *command, pgroup: true) do |stdin, stdout, stderr, thread|
        stdin.close
        out = Thread.new { stdout.read }
        err = Thread.new { stderr.read }

        if thread.join(@timeout)
          Result.new(stdout: out.value, stderr: err.value, exit_code: thread.value.exitstatus, timed_out: false)
        else
          terminate(thread.pid)
          Result.new(stdout: out.value.to_s, stderr: "#{err.value}\nTimed out after #{@timeout.to_i} seconds".strip,
                     exit_code: nil, timed_out: true)
        end
      end
    end

    # The program was started as its own process group leader, so the whole group goes: a
    # shell script's children would otherwise keep the pipes open and the readers waiting.
    def terminate(pid)
      Process.kill('KILL', -pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end
  end
end
