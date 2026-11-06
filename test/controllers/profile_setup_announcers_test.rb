require 'test_helper'

class ProfileSetupAnnouncersTest < ActionDispatch::IntegrationTest
  setup do
    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true
    @member = sign_in_as_plain_member
    @member.update!(profile_setup_completed_at: 1.day.ago)
    @slack = create_announcer(name: 'Post in Slack', description: 'Says hi in #space')
    @sign = create_announcer(name: 'Entry sign')
    @hidden = create_announcer(name: 'Retired', enabled: false)
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  def save(announce:, announcer_ids: [])
    post profile_setup_save_visibility_path, params: {
      user: { profile_visibility: 'members', greeting_option: 'custom', greeting_name: 'Ada',
              announce_arrivals: announce ? '1' : '0', announcer_ids: announcer_ids.map(&:id) }
    }
  end

  test 'lists enabled announcers with the editable help text' do
    TextFragment.create!(key: 'announce_arrivals_help', title: 'Help', content: '<p>Say hello to the room</p>')

    get profile_setup_visibility_path

    assert_response :success
    assert_match 'Announce arrivals', response.body
    assert_match 'Say hello to the room', response.body
    assert_match 'Post in Slack', response.body
    assert_match 'Says hi in #space', response.body
    assert_no_match 'Retired', response.body
  end

  test 'saves the switch and the chosen announcers' do
    save(announce: true, announcer_ids: [@slack])

    @member.reload
    assert @member.announce_arrivals?
    assert_equal [@slack], @member.announcers.to_a
  end

  test 'unchecking an announcer drops it but keeps a choice of a disabled one' do
    @member.announcer_subscriptions.create!(announcer: @sign)
    @member.announcer_subscriptions.create!(announcer: @hidden)

    save(announce: true, announcer_ids: [@slack])

    assert_equal [@slack, @hidden].map(&:id).sort, @member.reload.announcer_ids.sort
  end

  test 'switching announcements off keeps the choices for later' do
    @member.update!(announce_arrivals: true)
    @member.announcer_subscriptions.create!(announcer: @sign)

    save(announce: false)

    @member.reload
    assert_not @member.announce_arrivals?
    assert_equal [@sign], @member.announcers.to_a
  end

  test 'an announcer id the member cannot see is ignored' do
    save(announce: true, announcer_ids: [@hidden, @sign])

    assert_equal [@sign], @member.reload.announcers.to_a
  end

  test 'switching announcements on without ticking any announcer chooses every enabled one' do
    save(announce: true)

    assert_equal [@slack, @sign].map(&:id).sort, @member.reload.announcer_ids.sort
  end

  test 'saving with announcements on and nothing ticked fills in every enabled announcer' do
    @member.update!(announce_arrivals: true)
    @member.announcer_subscriptions.create!(announcer: @hidden)

    save(announce: true, announcer_ids: [@hidden])

    assert_equal [@slack, @sign, @hidden].map(&:id).sort, @member.reload.announcer_ids.sort
  end

  test 'switching on ticks every announcer in the page when none are ticked' do
    get profile_setup_visibility_path

    assert_match 'if (!anyChecked) boxes.forEach', response.body
  end
end
