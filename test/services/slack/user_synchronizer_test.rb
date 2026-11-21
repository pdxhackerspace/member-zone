require 'test_helper'

module Slack
  class UserSynchronizerTest < ActiveSupport::TestCase
    StubClient = Struct.new(:users) do
      def list_users
        users
      end
    end

    test 'refreshes slack users and links matching member without copying profile data by default' do
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

      client = StubClient.new(
        [
          {
            slack_id: 'U-MEMBER-SYNC',
            team_id: 'T123',
            username: 'slackmember',
            real_name: user.full_name,
            display_name: 'Slack Member',
            email: user.email,
            pronouns: 'they/them',
            title: 'Slack title',
            is_bot: false,
            deleted: false,
            raw_attributes: {
              'profile' => { 'image_original' => 'yes', 'image_192' => 'https://example.com/avatar.png' }
            },
            last_synced_at: Time.current
          }
        ]
      )

      result = Slack::UserSynchronizer.new(client: client).call

      slack_user = SlackUser.find_by!(slack_id: 'U-MEMBER-SYNC')
      assert_equal user.id, slack_user.user_id
      assert_equal 1, result.linked_count

      user.reload
      assert_nil user.slack_id
      assert_nil user.slack_handle
      assert_nil user.pronouns
      assert_nil user.bio
      assert_nil user.avatar
      assert_empty user.aliases
      assert_equal 0, result.updated_count
      assert_equal 0, result.created_count
    end

    test 'update_members copies slack profile data onto linked members' do
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

      client = StubClient.new(
        [
          {
            slack_id: 'U-MEMBER-UPDATE',
            username: 'slackmember',
            real_name: user.full_name,
            email: user.email,
            pronouns: 'they/them',
            title: 'Slack title',
            is_bot: false,
            deleted: false,
            raw_attributes: {
              'profile' => { 'image_original' => 'yes', 'image_192' => 'https://example.com/avatar.png' }
            },
            last_synced_at: Time.current
          }
        ]
      )

      result = Slack::UserSynchronizer.new(client: client).call(update_members: true)

      user.reload
      assert_equal 'U-MEMBER-UPDATE', user.slack_id
      assert_equal 'slackmember', user.slack_handle
      assert_equal 'they/them', user.pronouns
      assert_equal 'Slack title', user.bio
      assert_equal 'https://example.com/avatar.png', user.avatar
      assert_equal 1, result.updated_count
      assert_equal 0, result.created_count
    end

    test 'update_members refreshes an existing Slack avatar' do
      user = users(:two)
      user.update_columns(
        email: 'member-sync@example.com',
        avatar: 'https://avatars.slack-edge.com/existing-avatar.png',
        slack_id: nil,
        slack_handle: nil
      )

      client = StubClient.new(
        [
          {
            slack_id: 'U-MEMBER-AVATAR',
            username: 'slackmember',
            real_name: user.full_name,
            email: user.email,
            is_bot: false,
            deleted: false,
            raw_attributes: {
              'profile' => { 'image_original' => 'yes', 'image_192' => 'https://example.com/slack-avatar.png' }
            },
            last_synced_at: Time.current
          }
        ]
      )

      Slack::UserSynchronizer.new(client: client).call(update_members: true)

      assert_equal 'https://example.com/slack-avatar.png', user.reload.avatar
    end

    test 'update_members creates members for unmatched slack users' do
      client = StubClient.new(
        [
          {
            slack_id: 'U-NEW-MEMBER',
            username: 'newslack',
            real_name: 'Brand New Slack User',
            email: 'brand-new-slack@example.com',
            is_bot: false,
            deleted: false,
            raw_attributes: {},
            last_synced_at: Time.current
          }
        ]
      )

      assert_difference 'User.count', 1 do
        result = Slack::UserSynchronizer.new(client: client).call(update_members: true)
        assert_equal 1, result.created_count
        assert_equal 0, result.linked_count
      end

      slack_user = SlackUser.find_by!(slack_id: 'U-NEW-MEMBER')
      assert_not_nil slack_user.user_id
      assert_equal 'Brand New Slack User', slack_user.user.full_name
    end

    test 'workspace sync replaces a sign-in Gravatar and preserves its source across roster syncs' do
      user = users(:two)
      user.update!(avatar: 'https://secure.gravatar.com/avatar/old')
      claims = { 'picture' => user.avatar }
      slack_user = SlackUser.create!(slack_id: 'U-OIDC-PHOTO', user: user,
                                     raw_attributes: { 'openid_claims' => claims })
      photo = 'https://avatars.slack-edge.com/new-photo.png'
      client = StubClient.new([{ slack_id: slack_user.slack_id, is_bot: false, deleted: false,
                                 raw_attributes: { 'profile' => { 'image_192' => photo } } }])

      Slack::UserSynchronizer.new(client: client).call
      assert_equal claims, slack_user.reload.raw_attributes['openid_claims']
      assert_equal claims['picture'], user.reload.avatar

      Slack::UserSynchronizer.new(client: client).call(update_members: true)
      assert_equal photo, user.reload.avatar
      assert_equal claims, slack_user.reload.raw_attributes['openid_claims']
    end

    test 'links existing slack records that were imported earlier' do
      user = users(:two)
      user.update_columns(email: 'queued-link@example.com')
      SlackUser.create!(
        slack_id: 'U-QUEUED-LINK',
        email: user.email,
        real_name: user.full_name,
        is_bot: false,
        deleted: false
      )

      client = StubClient.new([])

      result = Slack::UserSynchronizer.new(client: client).call

      assert_equal 1, result.linked_count
      assert_equal 'U-QUEUED-LINK', user.reload.slack_user.slack_id
    end

    # The run shares one transaction, so a duplicate address rejected by the database must not
    # abort the members queued behind it.
    test 'a member whose address is already taken does not stop the rest of the sync' do
      SlackUser.create!(slack_id: 'U-INCUMBENT', email: 'contested@example.com')

      client = StubClient.new(
        [
          { slack_id: 'U-DUPLICATE', email: 'contested@example.com', real_name: 'Duplicate Address',
            is_bot: false, deleted: false },
          { slack_id: 'U-FOLLOWER', email: 'follower@example.com', real_name: 'Queued Behind',
            is_bot: false, deleted: false }
        ]
      )

      synchronizer = Slack::UserSynchronizer.new(client: client, logger: Logger.new(File::NULL))

      assert_nothing_raised { synchronizer.call }
      assert_not SlackUser.exists?(slack_id: 'U-DUPLICATE')
      assert SlackUser.exists?(slack_id: 'U-FOLLOWER')
    end
  end
end
