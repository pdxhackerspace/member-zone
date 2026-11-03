require 'test_helper'

module Announcers
  class PayloadBuilderTest < ActiveSupport::TestCase
    setup do
      @user = users(:one)
      @user.update!(use_full_name_for_greeting: false, greeting_name: 'Ada', profile_visibility: 'members',
                    slack_handle: 'ada')
      @announcer = create_announcer(name: 'Slack')
    end

    def payload(**)
      JSON.parse(PayloadBuilder.call(announcer: @announcer, user: @user, **))
    end

    test 'describes the member and links a shared profile' do
      data = payload

      assert_equal 'arrival', data['event']
      assert_equal 'Slack', data['announcer']
      assert_equal 'Ada', data.dig('member', 'name')
      assert_equal 'exampleuserone', data.dig('member', 'username')
      assert data.dig('member', 'profile_url').end_with?('/users/exampleuserone')
      assert_equal 'ada', data.dig('member', 'slack', 'handle')
    end

    test 'a private profile has no link' do
      @user.update!(profile_visibility: 'private')

      assert_nil payload.dig('member', 'profile_url')
    end

    test 'no slack details for a member without slack' do
      @user.update!(slack_handle: nil)
      SlackUser.where(user: @user).update_all(user_id: nil)
      @user.reload

      assert_nil payload.dig('member', 'slack')
    end

    test 'marks test runs' do
      assert payload(test_run: true)['test']
    end
  end
end
