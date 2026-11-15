require 'test_helper'
require 'active_job/test_helper'

class MessagesControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @sender = users(:one)
    @recipient = users(:two)
    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  test 'admin message folders and details keep the member dashboard navigation' do
    sign_in_as_local_admin
    admin = User.by_email(local_accounts(:active_admin).email).first!
    message = Message.create!(sender: @sender, recipient: admin, subject: 'Hello', body: 'Message body')

    Message::FOLDERS.each do |folder|
      get messages_path(folder: folder)
      assert_response :success
      assert_select 'a.nav-link.active', text: /Member Dashboard/
      assert_select 'a.nav-link.active[href=?]', messages_path(folder: :unread), text: /Messages/
      assert_select 'a.nav-link[href=?]', root_path(tab: :profile), text: /Profile/
    end
    get message_path(message)
    assert_response :success
    assert_select 'a.nav-link.active', text: /Member Dashboard/
    assert_select 'a.nav-link.active[href=?]', messages_path(folder: :unread), text: /Messages/
  end

  test 'member can open and delete a message while keeping the profile navigation' do
    member = member_user_for_local
    message = Message.create!(sender: @sender, recipient: member, subject: 'Hello member', body: 'Message body')
    sign_in_as_local_member
    get user_path(member, tab: :messages)
    assert_redirected_to messages_path(folder: :unread)
    follow_redirect!
    assert_select 'a.nav-link.active', text: /Messages/
    assert_select 'a.nav-link[href=?]', user_path(member, tab: :profile, view_as: :self), text: 'Profile'

    get message_path(message, folder: :unread)
    assert_response :success
    assert_select 'a.nav-link.active', text: /Messages/
    delete message_path(message, return_folder: :unread)
    follow_redirect!
    assert_response :success
    assert_select 'a.nav-link.active', text: /Messages/
    assert_select 'a.nav-link[href=?]', user_path(member, tab: :notifications, view_as: :self), text: 'Notifications'
  end

  test 'opening the last unread message clears the member navigation count' do
    member = member_user_for_local
    member.received_messages.update_all(read_at: Time.current)
    message = Message.create!(sender: @sender, recipient: member, subject: 'Unread', body: '.')
    sign_in_as_local_member

    get message_path(message)

    assert_response :success
    assert_not message.reload.unread?
    assert_select 'a.nav-link.active[href=?] span', messages_path(folder: :unread), count: 0
  end

  test 'staff without dashboard access can open notification preferences from messages' do
    member = member_user_for_local
    grant_privileges(member, 'members.view_profile')
    sign_in_as_local_member

    get messages_path
    assert_response :success
    notifications_path = user_path(member, tab: :notifications, view_as: :self)
    assert_select 'a.nav-link[href=?]', notifications_path, text: 'Notifications'
    assert_select 'a.nav-link[href=?]', user_path(member, tab: :profile, view_as: :self), text: 'Profile'

    get notifications_path
    assert_response :success
    assert_select 'h1', text: 'Notifications'
    assert_select 'form[action=?]', notification_preferences_path
  end

  # ─── Create: admin sending (existing behavior) ───────────────────

  test 'admin can send a message' do
    sign_in_as_local_admin

    assert_difference 'Message.count', 1 do
      post messages_path, params: {
        recipient_id: @recipient.id,
        subject: 'Test Subject',
        body: 'Test message body'
      }
    end

    message = Message.last
    assert_equal 'Test Subject', message.subject
    assert_equal 'Test message body', message.body
    assert_equal @recipient, message.recipient
    assert_redirected_to user_path(@recipient, tab: :messages)
    assert_equal 'Message sent.', flash[:notice]
  end

  test 'admin sending a message enqueues an email' do
    sign_in_as_local_admin

    assert_enqueued_emails 1 do
      post messages_path, params: {
        recipient_id: @recipient.id,
        subject: 'Email Test',
        body: 'This should trigger an email'
      }
    end
  end

  test 'admin gets error for missing subject' do
    sign_in_as_local_admin

    assert_no_difference 'Message.count' do
      post messages_path, params: {
        recipient_id: @recipient.id,
        subject: '',
        body: 'Test body'
      }
    end

    assert_redirected_to user_path(@recipient, tab: :messages)
    assert flash[:alert].present?
  end

  test 'admin gets error for missing body' do
    sign_in_as_local_admin

    assert_no_difference 'Message.count' do
      post messages_path, params: {
        recipient_id: @recipient.id,
        subject: 'Test Subject',
        body: ''
      }
    end

    assert_redirected_to user_path(@recipient, tab: :messages)
    assert flash[:alert].present?
  end

  test 'admin gets error for nonexistent recipient' do
    sign_in_as_local_admin

    post messages_path, params: {
      recipient_id: 999_999,
      subject: 'Test',
      body: 'Test'
    }

    assert_redirected_to users_path
    assert_equal 'Recipient not found.', flash[:alert]
  end

  # ─── Non-admin initiating a new message ─────────────────────────

  test 'non-admin cannot initiate a new message' do
    sign_in_as_local_member

    assert_no_difference 'Message.count' do
      post messages_path, params: {
        recipient_id: @recipient.id,
        subject: 'Test',
        body: 'Test'
      }
    end

    assert_redirected_to messages_path
    assert flash[:alert].present?
  end

  test 'unauthenticated user cannot send messages' do
    assert_no_difference 'Message.count' do
      post messages_path, params: {
        recipient_id: @recipient.id,
        subject: 'Test',
        body: 'Test'
      }
    end
  end

  # ─── Reply flow ─────────────────────────────────────────────────

  test 'recipient can reply to a message they received (non-admin)' do
    member_user = member_user_for_local
    original = Message.create!(
      sender: @sender,
      recipient: member_user,
      subject: 'Hello',
      body: 'Hi'
    )

    sign_in_as_local_member

    assert_difference 'Message.count', 1 do
      post messages_path, params: {
        in_reply_to_id: original.id,
        subject: 'Re: Hello',
        body: 'Reply body'
      }
    end

    reply = Message.last
    assert_equal member_user, reply.sender
    assert_equal @sender, reply.recipient
    assert_equal 'Re: Hello', reply.subject
    assert_redirected_to messages_path(folder: :sent)
    assert_equal 'Reply sent.', flash[:notice]
  end

  test 'non-recipient cannot reply to a message' do
    original = Message.create!(
      sender: @sender,
      recipient: @recipient,
      subject: 'Hello',
      body: 'Hi'
    )

    sign_in_as_local_member

    assert_no_difference 'Message.count' do
      post messages_path, params: {
        in_reply_to_id: original.id,
        subject: 'Re: Hello',
        body: 'Reply'
      }
    end

    assert_redirected_to messages_path
    assert flash[:alert].present?
  end

  # ─── Index ──────────────────────────────────────────────────────

  test 'unauthenticated user cannot view messages index' do
    get messages_path
    assert_redirected_to login_path
  end

  test 'index default folder shows unread received messages' do
    member_user = member_user_for_local
    Message.create!(sender: @sender, recipient: member_user, subject: 'Unread One', body: '.')
    read_msg = Message.create!(sender: @sender, recipient: member_user, subject: 'Read One', body: '.')
    read_msg.read!
    deleted = Message.create!(sender: @sender, recipient: member_user, subject: 'Deleted', body: '.')
    deleted.update!(deleted_by_recipient_at: Time.current)

    sign_in_as_local_member
    get messages_path
    assert_response :success

    body = response.body
    assert_includes body, 'Unread One'
    assert_not_includes body, 'Read One'
    assert_not_includes body, 'Deleted'
  end

  test 'index folder=read shows read received messages only' do
    member_user = member_user_for_local
    Message.create!(sender: @sender, recipient: member_user, subject: 'Unread One', body: '.')
    read_msg = Message.create!(sender: @sender, recipient: member_user, subject: 'Read One', body: '.')
    read_msg.read!

    sign_in_as_local_member
    get messages_path, params: { folder: :read }

    assert_response :success
    assert_includes response.body, 'Read One'
    assert_not_includes response.body, 'Unread One'
  end

  test 'index folder=sent shows messages authored by viewer' do
    member_user = member_user_for_local
    original = Message.create!(sender: @sender, recipient: member_user, subject: 'Hi', body: '.')
    Message.create!(sender: member_user, recipient: @sender, subject: 'From member', body: 'body')

    sign_in_as_local_member
    get messages_path, params: { folder: :sent }

    assert_response :success
    assert_includes response.body, 'From member'
    assert_not_includes response.body, original.subject
  end

  test 'index folder=all includes inbox and sent (non-trashed)' do
    member_user = member_user_for_local
    inbox = Message.create!(sender: @sender, recipient: member_user, subject: 'Inbox entry', body: '.')
    sent = Message.create!(sender: member_user, recipient: @sender, subject: 'Sent entry', body: '.')
    trashed = Message.create!(sender: @sender, recipient: member_user, subject: 'Trashed entry', body: '.')
    trashed.update!(deleted_by_recipient_at: Time.current)

    sign_in_as_local_member
    get messages_path, params: { folder: :all }

    assert_response :success
    assert_includes response.body, inbox.subject
    assert_includes response.body, sent.subject
    assert_not_includes response.body, trashed.subject
  end

  test 'index folder=trash includes deleted-within-30-days messages' do
    member_user = member_user_for_local
    recent = Message.create!(sender: @sender, recipient: member_user, subject: 'Recent trash', body: '.')
    recent.update!(deleted_by_recipient_at: 2.days.ago)
    expired = Message.create!(sender: @sender, recipient: member_user, subject: 'Expired trash', body: '.')
    expired.update!(deleted_by_recipient_at: 60.days.ago)

    sign_in_as_local_member
    get messages_path, params: { folder: :trash }

    assert_response :success
    assert_includes response.body, recent.subject
    assert_not_includes response.body, expired.subject
  end

  # ─── Show ───────────────────────────────────────────────────────

  test 'recipient viewing an unread message marks it read' do
    member_user = member_user_for_local
    message = Message.create!(sender: @sender, recipient: member_user, subject: 'Hi', body: '.')
    assert message.unread?

    sign_in_as_local_member
    get message_path(message)

    assert_response :success
    assert_not_nil message.reload.read_at
  end

  test 'sender viewing their own sent message does not change read_at' do
    member_user = member_user_for_local
    message = Message.create!(sender: member_user, recipient: @sender, subject: 'Mine', body: '.')
    assert_nil message.read_at

    sign_in_as_local_member
    get message_path(message)

    assert_response :success
    assert_nil message.reload.read_at
  end

  test 'show redirects when message is not visible to the user' do
    member_user = member_user_for_local
    assert member_user.present?
    other = Message.create!(sender: @sender, recipient: @recipient, subject: 'Not yours', body: '.')

    sign_in_as_local_member
    get message_path(other)

    assert_redirected_to messages_path
    assert_equal 'Message not found.', flash[:alert]
  end

  test 'show of a message in the viewer trash (within retention) succeeds' do
    member_user = member_user_for_local
    message = Message.create!(sender: @sender, recipient: member_user, subject: 'In trash', body: '.')
    message.update!(deleted_by_recipient_at: 3.days.ago)

    sign_in_as_local_member
    get message_path(message, folder: :trash)

    assert_response :success
    assert_includes response.body, 'In trash'
  end

  test 'show of a message whose trash has expired is not found' do
    member_user = member_user_for_local
    message = Message.create!(sender: @sender, recipient: member_user, subject: 'Expired', body: '.')
    message.update!(deleted_by_recipient_at: 60.days.ago)

    sign_in_as_local_member
    get message_path(message)

    assert_redirected_to messages_path
  end

  # ─── Destroy ────────────────────────────────────────────────────

  test 'recipient destroy soft-deletes for recipient only' do
    member_user = member_user_for_local
    message = Message.create!(sender: @sender, recipient: member_user, subject: 'Kill', body: '.')

    sign_in_as_local_member
    assert_no_difference 'Message.count' do
      delete message_path(message)
    end

    message.reload
    assert_not_nil message.deleted_by_recipient_at
    assert_nil message.deleted_by_sender_at
  end

  test 'sender destroy soft-deletes for sender only' do
    member_user = member_user_for_local
    message = Message.create!(sender: member_user, recipient: @sender, subject: 'Mine', body: '.')

    sign_in_as_local_member
    assert_no_difference 'Message.count' do
      delete message_path(message)
    end

    message.reload
    assert_not_nil message.deleted_by_sender_at
    assert_nil message.deleted_by_recipient_at
  end

  test 'destroy by unrelated user returns not found' do
    other = Message.create!(sender: @sender, recipient: @recipient, subject: 'Nope', body: '.')

    sign_in_as_local_member
    delete message_path(other)

    assert_redirected_to messages_path
    other.reload
    assert_nil other.deleted_by_sender_at
    assert_nil other.deleted_by_recipient_at
  end

  # ─── Mark unread ────────────────────────────────────────────────

  test 'recipient can mark a read message unread' do
    member_user = member_user_for_local
    message = Message.create!(sender: @sender, recipient: member_user, subject: 'Hi', body: '.')
    message.read!
    assert_not_nil message.read_at

    sign_in_as_local_member
    patch mark_unread_message_path(message)

    assert_redirected_to messages_path(folder: :unread)
    assert_nil message.reload.read_at
  end

  test 'sender cannot mark their own sent message unread' do
    member_user = member_user_for_local
    message = Message.create!(sender: member_user, recipient: @sender, subject: 'Out', body: '.')
    message.read!
    original_read_at = message.read_at

    sign_in_as_local_member
    patch mark_unread_message_path(message)

    assert_redirected_to message_path(message)
    assert_equal original_read_at.to_i, message.reload.read_at.to_i
  end

  # ─── Restore ────────────────────────────────────────────────────

  test 'recipient can restore a message from trash within 30 days' do
    member_user = member_user_for_local
    message = Message.create!(sender: @sender, recipient: member_user, subject: 'Save me', body: '.')
    message.update!(deleted_by_recipient_at: 2.days.ago)

    sign_in_as_local_member
    post restore_message_path(message)

    assert_redirected_to messages_path(folder: :all)
    assert_nil message.reload.deleted_by_recipient_at
  end

  test 'restoring a message past retention fails' do
    member_user = member_user_for_local
    message = Message.create!(sender: @sender, recipient: member_user, subject: 'Expired', body: '.')
    message.update!(deleted_by_recipient_at: 60.days.ago)

    sign_in_as_local_member
    post restore_message_path(message)

    assert_redirected_to messages_path
    assert_not_nil message.reload.deleted_by_recipient_at
  end

  private

  def sign_in_as_local_admin
    account = local_accounts(:active_admin)
    post local_login_path, params: {
      session: {
        email: account.email,
        password: 'localpassword123'
      }
    }
  end

  def sign_in_as_local_member
    account = local_accounts(:regular_member)
    post local_login_path, params: {
      session: {
        email: account.email,
        password: 'memberpassword123'
      }
    }
  end

  # The regular_member local account email matches the member_with_local_account user fixture;
  # signing in syncs that fixture user and sets session[:user_id] to its id.
  def member_user_for_local
    users(:member_with_local_account)
  end
end
