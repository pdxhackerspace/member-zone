require 'test_helper'

class AnnouncersControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true
    @announcer = create_announcer(name: 'Slack', environment_variables: 'SLACK_BOT_TOKEN=xoxb-secret')
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  def sign_in_manager
    member = sign_in_as_plain_member
    grant_privileges(member, 'announcers.manage')
    sign_in_as_plain_member
  end

  test 'only announcers.manage opens the configuration' do
    sign_in_as_plain_member
    [announcers_path, new_announcer_path, announcer_path(@announcer), edit_announcer_path(@announcer)].each do |path|
      get path
      assert_response :redirect, "#{path} should be closed to a plain member"
    end
  end

  test 'lists announcers and every known location' do
    AccessLog.create!(action: 'opened', location: 'unit2 front door', logged_at: Time.current)
    sign_in_manager

    get announcers_path

    assert_response :success
    assert_match 'Slack', response.body
    assert_match 'unit2 front door', response.body
    assert_no_match 'xoxb-secret', response.body
  end

  test 'shows, edits and offers a new announcer without revealing secrets' do
    sign_in_manager
    @announcer.announcer_runs.create!(user: users(:one), status: 'failed', exit_code: 2, output: 'nope')

    [announcer_path(@announcer), edit_announcer_path(@announcer), new_announcer_path].each do |path|
      get path
      assert_response :success, path
    end
    get announcer_path(@announcer)
    assert_match 'SLACK_BOT_TOKEN', response.body
    assert_no_match 'xoxb-secret', response.body
  end

  test 'creates an announcer with encrypted environment variables' do
    sign_in_manager

    post announcers_path, params: { announcer: {
      name: 'Entry sign', script_path: ANNOUNCER_FIXTURE_DIR.join('echo_payload.sh').to_s,
      environment_variables: 'SIGN_HOST=sign.lan', repeat_after_minutes: 90, enabled: '1'
    } }

    announcer = Announcer.find_by!(name: 'Entry sign')
    assert_redirected_to announcer_path(announcer)
    assert_equal 90, announcer.repeat_after_minutes
    assert_equal({ 'SIGN_HOST' => 'sign.lan' }, announcer.parsed_environment_variables)
    assert_not_includes Announcer.where(id: announcer.id).pick(:environment_variables), 'sign.lan'
  end

  test 'saves the outside doors' do
    sign_in_manager

    patch update_arrival_locations_announcers_path,
          params: { arrival_locations: ['unit2 front door'], new_location: 'back gate' }

    assert_redirected_to announcers_path
    assert_equal ['unit2 front door', 'back gate'], DefaultSetting.instance.arrival_locations
  end

  test 'a test announcement announces the signed-in manager' do
    manager = sign_in_manager

    assert_enqueued_with(job: Announcers::RunJob) { post test_announcer_path(@announcer) }

    run = @announcer.announcer_runs.last
    assert run.test_run?
    assert_equal manager, run.user
  end
end
