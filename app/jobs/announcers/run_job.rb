module Announcers
  # Runs one queued announcement. The claim is a single conditional UPDATE, so a run that two
  # workers are handed is only performed once.
  class RunJob < ApplicationJob
    queue_as :default

    def perform(run_id)
      run = AnnouncerRun.includes(:announcer, :user, :access_log).find_by(id: run_id)
      return if run.nil? || !claim(run)
      return finish(run, 'failed', 'Announcer was disabled before it ran.', nil) unless runnable?(run)

      execute(run)
    end

    private

    def claim(run)
      AnnouncerRun.where(id: run.id, status: 'queued').update_all(status: 'running', updated_at: Time.current) == 1
    end

    # A test run is how an admin checks an announcer before switching it on, so it ignores enabled.
    def runnable?(run)
      run.test_run? || run.announcer.enabled?
    end

    def execute(run)
      payload = PayloadBuilder.call(announcer: run.announcer, user: run.user, access_log: run.access_log,
                                    test_run: run.test_run?)
      result = ScriptRunner.call(run.announcer, payload)
      finish(run, result.success? ? 'success' : 'failed', result.output.presence, result.exit_code)
    rescue SystemCallError => e
      finish(run, 'failed', "Could not run #{run.announcer.script_path}: #{e.message}", nil)
    end

    def finish(run, status, output, exit_code)
      run.update!(status: status, output: output, exit_code: exit_code, finished_at: Time.current)
      run.announcer.record_run_result!(status)
    end
  end
end
