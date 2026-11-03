require 'open3'

module Announcers
  # Runs an announcer program with the arrival as JSON on stdin and returns what it printed.
  # Like AuditLogs::ScriptRunner it clears the app's Bundler settings (so a Ruby program loads
  # its own gems), never goes through a shell, and kills the whole process group if the program
  # outlives TIMEOUT. An announcement that takes a minute has missed its moment anyway.
  class ScriptRunner
    TIMEOUT = 60.seconds

    Result = Struct.new(:stdout, :stderr, :exit_code, :timed_out, keyword_init: true) do
      def success?
        !timed_out && exit_code&.zero?
      end

      def output
        [stdout, stderr].map { |text| text.to_s.strip }.compact_blank.join("\n")
      end
    end

    def self.call(announcer, payload, timeout: TIMEOUT)
      new(announcer, payload, timeout).call
    end

    def initialize(announcer, payload, timeout)
      @announcer = announcer
      @payload = payload
      @timeout = timeout
    end

    def call
      Bundler.with_unbundled_env { execute(environment, @announcer.command_arguments) }
    end

    def environment
      @announcer.parsed_environment_variables.merge('ANNOUNCER_NAME' => @announcer.name)
    end

    private

    def execute(env, command)
      program = [command.first, command.first]
      Open3.popen3(env, program, *command.drop(1), pgroup: true) do |stdin, stdout, stderr, thread|
        out = Thread.new { stdout.read }
        err = Thread.new { stderr.read }
        write_payload(stdin)

        if thread.join(@timeout)
          Result.new(stdout: out.value, stderr: err.value, exit_code: thread.value.exitstatus, timed_out: false)
        else
          terminate(thread.pid)
          Result.new(stdout: out.value.to_s, stderr: "#{err.value}\nTimed out after #{@timeout.to_i} seconds".strip,
                     exit_code: nil, timed_out: true)
        end
      end
    end

    # A program that never reads stdin may exit before the payload is written.
    def write_payload(stdin)
      stdin.write(@payload)
    rescue Errno::EPIPE
      nil
    ensure
      stdin.close
    end

    def terminate(pid)
      Process.kill('KILL', -pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end
  end
end
