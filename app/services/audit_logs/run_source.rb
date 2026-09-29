module AuditLogs
  # One scheduled run of a source: start the program, store what it printed, alert on what
  # is new, and leave a run record and the source's status behind. A failing program still
  # keeps whatever lines it printed before failing.
  class RunSource
    def self.call(source)
      new(source).call
    end

    def initialize(source)
      @source = source
    end

    def call
      started_at = Time.current
      run = start_run(started_at)

      begin
        finish(run, ScriptRunner.call(@source, since: @source.last_entry_at), started_at)
      rescue StandardError => e
        run.update!(status: 'failed', output: "Command failed: #{e.class}: #{e.message}")
        @source.update!(run_status: 'failed')
      end
      run
    end

    private

    def start_run(started_at)
      @source.update!(run_status: 'running', last_run_at: started_at)
      @source.audit_log_runs.create!(command_line: @source.command_arguments.join(' '), status: 'running')
    end

    def finish(run, result, started_at)
      added = store(result.stdout, started_at)
      status = result.success? ? 'success' : 'failed'
      run.update!(status: status, exit_code: result.exit_code, entries_added: added.size,
                  output: result.stderr.to_s.strip.presence&.truncate(20_000))
      @source.update!(run_status: status, last_entry_at: latest_entry_time(added, started_at))
      Alerter.call(@source, added) if added.any?
    end

    def store(stdout, started_at)
      entries = OutputParser.call(stdout, run_at: started_at)
      Ingestor.call(@source, entries).to_a
    end

    # The cursor handed back to the program as AUDIT_LOG_SINCE. It never runs ahead of the
    # start of this run, whatever the entries claim, or one bad timestamp would make programs
    # that honour it as a lower bound collect nothing from then on. A run that stored nothing
    # leaves the cursor exactly where it was: the start of the run is a ceiling, not a candidate.
    def latest_entry_time(added, started_at)
      newest = added.map(&:occurred_at).max
      return @source.last_entry_at if newest.nil?

      [[newest, started_at].min, @source.last_entry_at].compact.max
    end
  end
end
