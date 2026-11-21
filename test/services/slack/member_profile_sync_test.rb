require 'test_helper'

module Slack
  class MemberProfileSyncTest < ActiveSupport::TestCase
    test 'copies slack profile fields onto a linked member without overwriting existing values' do
      user = users(:two)
      user.update_columns(
        email: 'member-sync@example.com',
        aliases: [],
        slack_id: nil,
        slack_handle: nil,
        pronouns: nil,
        bio: nil,
        avatar: nil
      )

      slack_user = SlackUser.create!(
        slack_id: 'U-PROFILE-SYNC',
        username: 'slackmember',
        real_name: 'Slack Display Name',
        email: 'slack-only@example.com',
        pronouns: 'they/them',
        title: 'Slack title',
        raw_attributes: {
          'profile' => {
            'image_original' => 'yes',
            'image_192' => 'https://example.com/avatar.png',
            'fields' => {
              'Xf123' => { 'label' => 'GitHub', 'value' => 'https://github.com/example' }
            }
          }
        }
      )

      MemberProfileSync.apply(user: user, slack_user: slack_user)

      user.reload
      assert_equal 'U-PROFILE-SYNC', user.slack_id
      assert_equal 'slackmember', user.slack_handle
      assert_equal 'they/them', user.pronouns
      assert_equal 'Slack title', user.bio
      assert_equal 'https://example.com/avatar.png', user.avatar
      assert_includes user.aliases, 'Slack Display Name'
      assert_includes user.extra_emails, 'slack-only@example.com'
      assert_equal 1, user.user_links.count
      assert_equal 'GitHub', user.user_links.first.title
    end

    test 'does not overwrite an existing member avatar' do
      user = users(:two)
      user.update_columns(
        avatar: 'https://example.com/existing-avatar.png',
        slack_id: 'U-EXISTING',
        slack_handle: 'existing'
      )

      slack_user = SlackUser.create!(
        slack_id: 'U-EXISTING',
        username: 'slackmember',
        raw_attributes: {
          'profile' => {
            'image_original' => 'yes',
            'image_192' => 'https://example.com/slack-avatar.png'
          }
        }
      )

      MemberProfileSync.apply(user: user, slack_user: slack_user)

      assert_equal 'https://example.com/existing-avatar.png', user.reload.avatar
    end

    test 'does not store a Slack default Gravatar when the member has no uploaded photo' do
      user = users(:two)
      user.update_columns(avatar: nil)
      gravatar = 'https://secure.gravatar.com/avatar/abc?s=192&d=' \
                 'https%3A%2F%2Fa.slack-edge.com%2Fdf10d%2Fimg%2Favatars%2Fava_0001-192.png'
      slack_user = SlackUser.create!(
        slack_id: 'U-DEFAULT-AVATAR',
        raw_attributes: { 'profile' => { 'image_192' => gravatar } }
      )

      MemberProfileSync.apply(user: user, slack_user: slack_user)

      assert_nil user.reload.avatar
    end

    test 'replaces a stored Slack default Gravatar once a real photo exists' do
      user = users(:two)
      gravatar = 'https://secure.gravatar.com/avatar/abc?s=192&d=' \
                 'https%3A%2F%2Fa.slack-edge.com%2Fdf10d%2Fimg%2Favatars%2Fava_0001-192.png'
      user.update_columns(avatar: gravatar)
      slack_user = SlackUser.create!(
        slack_id: 'U-UPLOADED-AVATAR',
        raw_attributes: {
          'profile' => {
            'image_original' => 'https://avatars.slack-edge.com/original.png',
            'image_192' => 'https://avatars.slack-edge.com/new.png'
          }
        }
      )

      MemberProfileSync.apply(user: user, slack_user: slack_user)

      assert_equal 'https://avatars.slack-edge.com/new.png', user.reload.avatar
    end

    test 'does not replace a member gravatar that did not come from Slack' do
      user = users(:two)
      user.update_columns(avatar: 'https://secure.gravatar.com/avatar/theirs')
      slack_user = SlackUser.create!(
        slack_id: 'U-CUSTOM-GRAVATAR',
        raw_attributes: {
          'profile' => {
            'image_original' => 'yes',
            'image_192' => 'https://avatars.slack-edge.com/new.png'
          }
        }
      )

      MemberProfileSync.apply(user: user, slack_user: slack_user)

      assert_equal 'https://secure.gravatar.com/avatar/theirs', user.reload.avatar
    end

    test 'refreshes a Slack avatar and preserves it when the latest URL is missing' do
      user = users(:two)
      user.update_columns(avatar: 'https://avatars.slack-edge.com/old.png')
      slack_user = SlackUser.new(raw_attributes: {
                                   'profile' => { 'image_192' => 'https://avatars.slack-edge.com/new.png' }
                                 })

      MemberProfileSync.apply(user: user, slack_user: slack_user)
      assert_equal 'https://avatars.slack-edge.com/new.png', user.reload.avatar

      slack_user.raw_attributes = { 'profile' => {} }
      MemberProfileSync.apply(user: user, slack_user: slack_user)
      assert_equal 'https://avatars.slack-edge.com/new.png', user.reload.avatar
    end
  end
end
