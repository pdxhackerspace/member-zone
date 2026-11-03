require 'test_helper'

class ProfileSetupInterestsTest < ActionDispatch::IntegrationTest
  setup do
    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true
    # Sign in as the member_with_local_account fixture user via their local account
    sign_in_as_member
    @current_user = User.lookup_by_email(local_accounts(:regular_member).email)
    @current_user.update!(profile_setup_completed_at: 1.day.ago)
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  # GET /profile/setup/interests

  test 'shows the interests step' do
    get profile_setup_interests_path
    assert_response :success
    assert_match(/Interests/i, response.body)
  end

  test 'shows the entire interest tag cloud' do
    get profile_setup_interests_path
    assert_response :success
    Interest.find_each do |interest|
      assert_match interest.name, response.body
    end
  end

  test 'shows the interest search box and no-results message' do
    get profile_setup_interests_path
    assert_response :success
    assert_select "input[data-live-filter-target='input']"
    assert_select "[data-live-filter-target='noResults']", text: /No interests match/i
  end

  test 'selected interest pills stay visible during search via keep-visible' do
    interest = interests(:electronics)
    @current_user.interests << interest unless @current_user.interests.include?(interest)

    get profile_setup_interests_path
    assert_response :success
    assert_select "#pill_interest_#{interest.id}[data-live-filter-keep-visible='true']"
    assert_select "#pill_interest_#{interests(:laser_cutting).id}[data-live-filter-keep-visible='false']"
  end

  test 'shows completely optional notice' do
    get profile_setup_interests_path
    assert_match(/completely optional/i, response.body)
  end

  test 'shows skip and continue buttons' do
    get profile_setup_interests_path
    assert_match(/Skip/i, response.body)
    assert_match(/Continue/i, response.body)
  end

  test 'skip and continue links go to visibility step' do
    get profile_setup_interests_path
    assert_select "a[href='#{profile_setup_visibility_path}']"
  end

  test 'requires authentication' do
    # Sign out by clearing session
    begin
      delete logout_path
    rescue StandardError
      nil
    end
    get profile_setup_interests_path
    assert_redirected_to login_path
  end

  # POST /profile/setup/interests/:id/add

  test 'adds an interest to the current user' do
    interest = interests(:laser_cutting)
    assert_not @current_user.interests.include?(interest)

    assert_difference -> { @current_user.reload.interests.count }, 1 do
      post profile_setup_add_interest_path(interest), headers: { 'Accept' => 'text/html' }
    end

    assert_redirected_to profile_setup_interests_path
    assert @current_user.reload.interests.include?(interest)
  end

  test 'add responds with a turbo stream replacing the pill' do
    interest = interests(:laser_cutting)

    assert_difference -> { @current_user.reload.interests.count }, 1 do
      post profile_setup_add_interest_path(interest), as: :turbo_stream
    end

    assert_response :success
    assert_match(/turbo-stream action="replace" target="pill_interest_#{interest.id}"/, response.body)
    # The replacement pill is now in the selected state (remove form)
    assert_match profile_setup_remove_interest_path(interest), response.body
    assert_match(/data-live-filter-keep-visible="true"/, response.body)
  end

  test 'does not add the same interest twice' do
    # Give the user electronics first
    @current_user.interests << interests(:electronics) unless @current_user.interests.include?(interests(:electronics))

    assert_no_difference -> { @current_user.reload.interests.count } do
      post profile_setup_add_interest_path(interests(:electronics)), headers: { 'Accept' => 'text/html' }
    end

    assert_redirected_to profile_setup_interests_path
  end

  test 'redirects gracefully for a non-existent interest id on add' do
    post profile_setup_add_interest_path(id: 999_999)
    assert_redirected_to profile_setup_interests_path
  end

  # DELETE /profile/setup/interests/:id/remove

  test 'removes an interest from the current user' do
    interest = interests(:electronics)
    @current_user.interests << interest unless @current_user.interests.include?(interest)

    assert_difference -> { @current_user.reload.interests.count }, -1 do
      delete profile_setup_remove_interest_path(interest), headers: { 'Accept' => 'text/html' }
    end

    assert_redirected_to profile_setup_interests_path
    assert_not @current_user.reload.interests.include?(interest)
  end

  test 'remove responds with a turbo stream replacing the pill' do
    interest = interests(:electronics)
    @current_user.interests << interest unless @current_user.interests.include?(interest)

    assert_difference -> { @current_user.reload.interests.count }, -1 do
      delete profile_setup_remove_interest_path(interest), as: :turbo_stream
    end

    assert_response :success
    assert_match(/turbo-stream action="replace" target="pill_interest_#{interest.id}"/, response.body)
    # The replacement pill is now in the unselected state (add form)
    assert_match profile_setup_add_interest_path(interest), response.body
    assert_match(/data-live-filter-keep-visible="false"/, response.body)
  end

  test 'redirects gracefully for a non-existent interest id on remove' do
    delete profile_setup_remove_interest_path(id: 999_999)
    assert_redirected_to profile_setup_interests_path
  end

  # POST /profile/setup/interests/suggest

  test 'suggest creates a new interest with needs_review true and adds it to the user' do
    assert_difference 'Interest.count', 1 do
      post profile_setup_suggest_interest_path, params: { interest_name: 'Textile Electronics' }
    end
    new_interest = Interest.find_by(name: 'Textile Electronics')
    assert new_interest.needs_review?
    assert_not new_interest.seeded?
    assert @current_user.reload.interests.include?(new_interest)
    assert_redirected_to profile_setup_interests_path
    assert_match(/added to your profile/i, flash[:notice])
  end

  test 'suggest with an existing interest reuses it and adds to the user' do
    existing = interests(:laser_cutting)
    assert_no_difference 'Interest.count' do
      post profile_setup_suggest_interest_path, params: { interest_name: existing.name }
    end
    assert @current_user.reload.interests.include?(existing)
    assert_redirected_to profile_setup_interests_path
  end

  test 'suggest is case-insensitive when matching existing interests' do
    assert_no_difference 'Interest.count' do
      post profile_setup_suggest_interest_path, params: { interest_name: 'ELECTRONICS' }
    end
    assert @current_user.reload.interests.include?(interests(:electronics))
  end

  test 'suggest with blank name redirects with alert and does not create interest' do
    assert_no_difference 'Interest.count' do
      post profile_setup_suggest_interest_path, params: { interest_name: '   ' }
    end
    assert_redirected_to profile_setup_interests_path
    assert_match(/enter an interest name/i, flash[:alert])
  end

  test 'suggest requires authentication' do
    begin
      delete logout_path
    rescue StandardError
      nil
    end
    post profile_setup_suggest_interest_path, params: { interest_name: 'Test' }
    assert_redirected_to login_path
  end

  private

  def sign_in_as_member
    post local_login_path, params: {
      session: { email: local_accounts(:regular_member).email, password: 'memberpassword123' }
    }
  end
end
