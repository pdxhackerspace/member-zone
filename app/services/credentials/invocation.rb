module Credentials
  # One logged call to a provider's program: writes the CredentialRun, runs the action, has
  # the block validate stdout, and records how it ended. stdout itself is never stored; the
  # run keeps stderr and any error, with the provider's environment values and every string
  # the program printed on stdout blanked out first, so neither its API keys nor an issued
  # secret can leak into the log by being echoed.
  class Invocation
    NOT_CONFIGURED_EXIT = 2
    OUTPUT_LIMIT = 20_000
    NOT_IN_CATALOG = 'Program is no longer an executable in a credential script directory'.freeze

    Outcome = Struct.new(:ok, :value, :error, :not_configured, :run, :stdout, keyword_init: true) do
      alias_method :ok?, :ok
    end

    def self.call(provider, action, credential: nil, input: nil, timeout: nil, &)
      new(provider, action.to_s, credential, input, timeout).call(&)
    end

    def initialize(provider, action, credential, input, timeout)
      @provider = provider
      @action = action
      @credential = credential
      @input = input
      @timeout = timeout
    end

    def call
      run = start_run
      return finish_run(run, Outcome.new(ok: false, error: NOT_IN_CATALOG), nil) unless program_allowed?

      result = ScriptRunner.call(@provider, @action, input: @input, timeout: @timeout)
      outcome = interpret(result) { |stdout| block_given? ? yield(stdout) : true }
      finish_run(run, outcome, result)
    rescue SystemCallError => e
      finish_run(run, Outcome.new(ok: false, error: "Could not run #{@provider.script_path}: #{e.message}"), nil)
    end

    private

    # The path was checked when it was saved, but the file may have moved, lost its execute
    # bit, or the directory list may have changed since.
    def program_allowed?
      ScriptCatalog.allowed?(@provider.script_path.to_s.strip)
    end

    def interpret(result)
      unless result.success?
        return Outcome.new(ok: false, not_configured: result.exit_code == NOT_CONFIGURED_EXIT,
                           error: failure_message(result), stdout: result.stdout)
      end

      Outcome.new(ok: true, value: yield(result.stdout), stdout: result.stdout)
    rescue Protocol::Error => e
      Outcome.new(ok: false, error: "Invalid #{@action} output: #{e.message}", stdout: result.stdout)
    end

    def failure_message(result)
      return "Timed out after #{result.duration_ms.to_i / 1000} seconds" if result.timed_out
      return 'Not configured (exit 2)' if result.exit_code == NOT_CONFIGURED_EXIT

      "Exited with status #{result.exit_code}"
    end

    def start_run
      CredentialRun.create!(credential_provider: @provider, credential: @credential, action: @action,
                            command_line: redactor(nil).call(@provider.command_arguments(@action).join(' ')),
                            status: 'running')
    end

    def finish_run(run, outcome, result)
      redact = redactor(outcome.stdout)
      output = [outcome.error, result&.stderr.presence].compact.join("\n")
      run.update!(status: outcome.ok? ? 'success' : 'failed', exit_code: result&.exit_code,
                  duration_ms: result&.duration_ms, output: redact.call(output).truncate(OUTPUT_LIMIT).presence)
      outcome.run = run
      outcome.error = redact.call(outcome.error) if outcome.error
      outcome
    end

    def redactor(stdout)
      Redactor.new(@provider.parsed_environment_variables.values + printed_strings(stdout))
    end

    # For an issue, everything the program printed is potentially secret: every string in its
    # JSON, valid against the protocol or not, or every word when it is not JSON at all. Other
    # actions print nothing secret, and redacting their words would only garble the log.
    def printed_strings(stdout)
      return [] if @action != 'issue' || stdout.blank?

      leaf_strings(JSON.parse(stdout))
    rescue JSON::ParserError
      stdout.split(/\s+/)
    end

    def leaf_strings(value)
      case value
      when Hash then value.values.flat_map { |nested| leaf_strings(nested) }
      when Array then value.flat_map { |nested| leaf_strings(nested) }
      when String then [value]
      else []
      end
    end
  end
end
