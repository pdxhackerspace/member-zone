require 'test_helper'

module Announcers
  class RunJobTest < ActiveJob::TestCase
    setup do
      @user = users(:one)
      @user.update!(use_full_name_for_greeting: false, greeting_name: 'Ada', pronouns: 'she/her')
      @access_log = AccessLog.create!(user: @user, action: 'opened', location: 'unit2 front door',
                                      logged_at: Time.zone.parse('2026-11-02 18:00:00'))
    end

    test 'runs the program with secrets in the environment and the arrival on stdin' do
      announcer = create_announcer(environment_variables: 'ANNOUNCER_TEST_TOKEN=s3cret', script_arguments: '--loud')
      run = announcer.announcer_runs.create!(user: @user, access_log: @access_log)

      RunJob.perform_now(run.id)

      run.reload
      assert_equal 'success', run.status
      assert_equal 0, run.exit_code
      assert_includes run.output, 'args: announce --loud'
      assert_includes run.output, "token: s3cret name: #{announcer.name}"
      payload = JSON.parse(run.output.lines.drop(2).join)
      assert_equal 'Ada', payload.dig('member', 'name')
      assert_equal 'she/her', payload.dig('member', 'pronouns')
      assert_equal 'unit2 front door', payload.dig('access', 'location')
      assert_equal false, payload['test']
      assert_equal 'success', announcer.reload.last_run_status
    end

    test 'records a failing program' do
      announcer = create_announcer(script: 'failing.sh')
      run = announcer.announcer_runs.create!(user: @user, access_log: @access_log)

      RunJob.perform_now(run.id)

      run.reload
      assert_equal 'failed', run.status
      assert_equal 3, run.exit_code
      assert_includes run.output, 'slack said no'
      assert_equal 'failed', announcer.reload.last_run_status
    end

    test 'does not run an announcer disabled after the run was queued, unless it is a test' do
      announcer = create_announcer(enabled: false)
      run = announcer.announcer_runs.create!(user: @user, access_log: @access_log)
      test_run = announcer.announcer_runs.create!(user: @user, test_run: true)

      RunJob.perform_now(run.id)
      RunJob.perform_now(test_run.id)

      assert_equal 'failed', run.reload.status
      assert_nil run.exit_code
      assert_equal 'success', test_run.reload.status
    end

    test 'a run already claimed is left alone' do
      announcer = create_announcer
      run = announcer.announcer_runs.create!(user: @user, status: 'running')

      RunJob.perform_now(run.id)

      assert_equal 'running', run.reload.status
    end
  end
end
