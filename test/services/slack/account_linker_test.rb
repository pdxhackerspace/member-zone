# frozen_string_literal: true

require 'test_helper'

module Slack
  class AccountLinkerTest < ActiveSupport::TestCase
    setup do
      @cfg = Rails.application.config.x.slack_oidc
      @prev = {
        client_id: @cfg.client_id,
        client_secret: @cfg.client_secret,
        team_id: @cfg.team_id
      }
      @cfg.client_id = 'test_client'
      @cfg.client_secret = 'test_secret'
      @cfg.team_id = 'T123'
    end

    teardown do
      @cfg.client_id = @prev[:client_id]
      @cfg.client_secret = @prev[:client_secret]
      @cfg.team_id = @prev[:team_id]
    end

    test 'links unlinked SlackUser to user when team and sub match' do
      user = users(:member_with_local_account)
      user.update!(avatar: nil)
      su = slack_users(:with_dept)
      su.update_columns(user_id: nil)

      result = AccountLinker.call(
        user: user,
        id_token_payload: {
          'sub' => su.slack_id,
          'https://slack.com/team_id' => 'T123',
          'picture' => 'https://avatars.slack-edge.com/sign-in.png'
        }
      )

      assert result.success?
      assert_equal user.id, su.reload.user_id
      assert_equal 'https://avatars.slack-edge.com/sign-in.png', user.reload.avatar
    end

    test 'refreshes the photo when an already linked member signs in again' do
      user = users(:member_with_local_account)
      user.update!(avatar: 'https://secure.gravatar.com/avatar/old')
      su = slack_users(:with_dept)
      su.update!(user_id: user.id, raw_attributes: {
                   'profile' => { 'title' => 'Keep this profile' },
                   'openid_claims' => { 'picture' => user.avatar }
                 })

      result = AccountLinker.call(user: user, id_token_payload: {
                                    'sub' => su.slack_id,
                                    'https://slack.com/team_id' => 'T123',
                                    'picture' => 'https://secure.gravatar.com/avatar/new'
                                  })

      assert result.success?
      assert_equal 'https://secure.gravatar.com/avatar/new', user.reload.avatar
      assert_equal user.avatar, su.reload.raw_attributes.dig('openid_claims', 'picture')
      assert_equal 'Keep this profile', su.raw_attributes.dig('profile', 'title')
    end

    test 'preserves custom photos and keeps the last photo when a sign-in omits picture' do
      user = users(:member_with_local_account)
      user.update!(avatar: 'https://example.com/custom.png')
      su = slack_users(:with_dept)
      su.update!(user_id: user.id)
      payload = { 'sub' => su.slack_id, 'https://slack.com/team_id' => 'T123',
                  'picture' => 'https://avatars.slack-edge.com/sign-in.png' }

      assert AccountLinker.call(user: user, id_token_payload: payload).success?
      assert_equal 'https://example.com/custom.png', user.reload.avatar

      user.update!(avatar: payload.delete('picture'))
      assert AccountLinker.call(user: user, id_token_payload: payload).success?
      assert_equal 'https://avatars.slack-edge.com/sign-in.png', user.reload.avatar
    end

    test 'fails when workspace team does not match' do
      user = users(:member_with_local_account)
      su = slack_users(:with_dept)
      su.update_columns(user_id: nil)

      result = AccountLinker.call(
        user: user,
        id_token_payload: {
          'sub' => su.slack_id,
          'https://slack.com/team_id' => 'T999'
        }
      )

      assert result.failure?
      assert_nil su.reload.user_id
    end

    test 'fails when Slack user is already linked to another member' do
      user = users(:member_with_local_account)
      user.update!(avatar: 'https://example.com/custom.png')
      other = users(:two)
      su = slack_users(:with_dept)
      su.update!(user_id: other.id)
      original_avatar = user.avatar
      original_attributes = su.raw_attributes

      result = AccountLinker.call(
        user: user,
        id_token_payload: {
          'sub' => su.slack_id,
          'https://slack.com/team_id' => 'T123',
          'picture' => 'https://avatars.slack-edge.com/other.png'
        }
      )

      assert result.failure?
      assert_equal other.id, su.reload.user_id
      assert_equal original_avatar, user.reload.avatar
      assert_equal original_attributes, su.raw_attributes
    end
  end
end
