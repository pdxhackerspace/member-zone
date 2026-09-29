require 'test_helper'

module AuditLogs
  class AlertRecipientsTest < ActiveSupport::TestCase
    setup do
      @topic = TrainingTopic.create!(name: "Doors #{SecureRandom.hex(3)}")
      @source = create_audit_log_source(training_topic: @topic)
    end

    def recipients(source = @source)
      AlertRecipients.call(source)
    end

    test 'nobody is alerted when nobody holds an alert privilege' do
      assert_empty recipients
    end

    test 'holders of alerts_all are alerted for every source' do
      user = users(:one)
      grant_privileges(user, 'audit_logs.alerts_all')

      assert_includes recipients, user
      assert_includes recipients(create_audit_log_source), user
    end

    test 'administrators are alerted' do
      admin = users(:two)
      admin.update_columns(is_admin: true)

      assert_includes recipients, admin
      assert_includes recipients(create_audit_log_source), admin
    end

    test 'a topic-scoped holder is alerted for their topic only' do
      user = users(:one)
      grant_privileges(user, 'audit_logs.alerts', topic: @topic)

      assert_includes recipients, user
      elsewhere = TrainingTopic.create!(name: "Elsewhere #{SecureRandom.hex(3)}")
      assert_not_includes recipients(create_audit_log_source(training_topic: elsewhere)), user
      assert_not_includes recipients(create_audit_log_source), user
    end

    test 'a topic-scoped holder is alerted through the parent of the source topic' do
      parent = TrainingTopic.create!(name: "Parent #{SecureRandom.hex(3)}")
      child = TrainingTopic.create!(name: "Child #{SecureRandom.hex(3)}", parent: parent)
      user = users(:one)
      grant_privileges(user, 'audit_logs.alerts', topic: parent)

      assert_includes recipients(create_audit_log_source(training_topic: child)), user
    end

    test 'a topic held only through the child does not reach the parent source' do
      parent = TrainingTopic.create!(name: "Parent #{SecureRandom.hex(3)}")
      child = TrainingTopic.create!(name: "Child #{SecureRandom.hex(3)}", parent: parent)
      user = users(:one)
      grant_privileges(user, 'audit_logs.alerts', topic: child)

      assert_not_includes recipients(create_audit_log_source(training_topic: parent)), user
    end

    test 'can_train holders are covered when the role is attached to that population' do
      user = users(:one)
      grant_privileges(user, 'audit_logs.alerts', topic: @topic, member_source: 'can_train')

      assert_includes recipients, user
    end

    test 'view privileges alone do not make someone a recipient' do
      user = users(:one)
      grant_privileges(user, 'audit_logs.view_all', 'audit_logs.view', topic: @topic)

      assert_not_includes recipients, user
    end

    test 'a person qualifying more than one way appears once' do
      user = users(:one)
      user.update_columns(is_admin: true)
      grant_privileges(user, 'audit_logs.alerts_all')
      grant_privileges(user, 'audit_logs.alerts', topic: @topic)

      assert_equal 1, recipients.count(user)
    end

    test 'inactive accounts and accounts with no email are skipped' do
      inactive = users(:one)
      inactive.update_columns(is_admin: true, active: false)
      no_email = users(:no_email)
      no_email.update_columns(is_admin: true)

      assert_not_includes recipients, inactive
      assert_not_includes recipients, no_email
    end
  end
end
