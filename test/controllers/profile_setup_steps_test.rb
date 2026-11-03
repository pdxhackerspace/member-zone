require 'test_helper'

class ProfileSetupStepsTest < ActionDispatch::IntegrationTest
  STEP_PATHS = {
    'Basic Info' => :profile_setup_path,
    'About You' => :profile_setup_optional_path,
    'Links' => :profile_setup_links_path,
    'Interests' => :profile_setup_interests_path,
    'Visibility' => :profile_setup_visibility_path
  }.freeze

  setup do
    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true
    @member = sign_in_as_plain_member
    # Starts on a first pass; the editing tests stamp it as set up.
    @member.update!(profile_setup_completed_at: nil)
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  def save_basic_info
    post profile_setup_save_basic_path,
         params: { user: { full_name: 'Ada Lovelace', email: @member.email, username: 'ada' } }
  end

  test 'a first pass shows the steps as plain text' do
    get profile_setup_path

    assert_response :success
    assert_select 'nav[aria-label=?]', 'Profile setup steps' do
      assert_select 'a', count: 0
      STEP_PATHS.each_key { |title| assert_select 'span', text: title }
    end
  end

  test 'a first pass cannot jump past basic info' do
    STEP_PATHS.except('Basic Info').each_value do |path|
      get public_send(path)
      assert_redirected_to profile_setup_path
    end

    post profile_setup_save_visibility_path, params: { user: { profile_visibility: 'members' } }
    assert_redirected_to profile_setup_path
    assert_nil @member.reload.profile_setup_completed_at
  end

  test 'a first pass moves on once basic info is saved, and stays plain text' do
    save_basic_info
    assert_redirected_to profile_setup_optional_path

    get profile_setup_interests_path
    assert_response :success
    assert_select 'nav[aria-label=?] a', 'Profile setup steps', count: 0
  end

  test 'finishing the wizard marks the profile as set up' do
    save_basic_info

    freeze_time do
      post profile_setup_save_visibility_path,
           params: { user: { profile_visibility: 'members', greeting_option: 'full_name' } }
      assert_redirected_to user_path(@member.reload)
      assert_equal Time.current, @member.profile_setup_completed_at
    end
  end

  test 'a first pass that fails to finish is still a first pass' do
    save_basic_info

    post profile_setup_save_visibility_path, params: { user: { profile_visibility: 'everyone-ever' } }

    assert_response :unprocessable_content
    assert_select 'nav[aria-label=?] a', 'Profile setup steps', count: 0
    assert_nil @member.reload.profile_setup_completed_at
  end

  test 'editing a set-up profile links every other step' do
    @member.update!(profile_setup_completed_at: 1.day.ago)

    get profile_setup_links_path

    assert_response :success
    assert_select 'nav[aria-label=?]', 'Profile setup steps' do
      STEP_PATHS.except('Links').each do |title, path|
        assert_select 'a[href=?]', public_send(path), text: title
      end
      assert_select '[aria-current=step]', text: /Links/
      assert_select 'a[href=?]', profile_setup_links_path, count: 0
    end
  end

  test 'editing a set-up profile can open any step directly and keeps its date' do
    completed_at = 1.day.ago.change(usec: 0)
    @member.update!(profile_setup_completed_at: completed_at)

    STEP_PATHS.each_value do |path|
      get public_send(path)
      assert_response :success
    end

    post profile_setup_save_visibility_path,
         params: { user: { profile_visibility: 'members', greeting_option: 'full_name' } }
    assert_equal completed_at, @member.reload.profile_setup_completed_at
  end
end
