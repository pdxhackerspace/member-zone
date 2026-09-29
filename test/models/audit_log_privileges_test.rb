require 'test_helper'

class AuditLogPrivilegesTest < ActiveSupport::TestCase
  KEYS = %w[audit_logs.view_all audit_logs.view audit_logs.alerts_all audit_logs.alerts audit_logs.manage].freeze

  setup { Privilege.seed_defaults! }

  test 'the catalog defines the five audit log privileges' do
    assert_equal KEYS.sort, Privilege::CATALOG.pluck(:key).grep(/\Aaudit_logs\./).sort
  end

  test 'the per-topic keys are topic scoped and the rest are global' do
    scopes = Privilege.where(key: KEYS).to_h { |privilege| [privilege.key, privilege.privilege_scope] }

    assert_equal 'topic', scopes['audit_logs.view']
    assert_equal 'topic', scopes['audit_logs.alerts']
    assert_equal 'global', scopes['audit_logs.view_all']
    assert_equal 'global', scopes['audit_logs.alerts_all']
    assert_equal 'global', scopes['audit_logs.manage']
  end

  test 'seeding creates an Audit log administrator role with every global privilege' do
    Role.seed_defaults!

    role = Role.find_by!(name: 'Audit log administrator')
    assert_equal %w[audit_logs.alerts_all audit_logs.manage audit_logs.view_all], role.privilege_keys.sort
  end

  test 'seeding creates an Audit log reviewer role meant to be attached to a topic' do
    Role.seed_defaults!

    role = Role.find_by!(name: 'Audit log reviewer')
    assert_equal %w[audit_logs.alerts audit_logs.view], role.privilege_keys.sort
    assert_predicate role.privileges.map(&:privilege_scope).uniq, :one?
  end

  test 'seeding does not overwrite an administrator edit to the role' do
    Role.seed_defaults!
    role = Role.find_by!(name: 'Audit log reviewer')
    role.update!(privileges: Privilege.where(key: 'audit_logs.view'))

    Role.seed_defaults!

    assert_equal ['audit_logs.view'], role.reload.privilege_keys
  end

  test 'administrators hold every audit log privilege without any role' do
    admin = users(:one)
    admin.update_columns(is_admin: true)

    KEYS.each { |key| assert admin.can?(key), "admin should hold #{key}" }
  end

  test 'a plain member holds none' do
    KEYS.each { |key| assert_not users(:two).can?(key), "plain member should not hold #{key}" }
  end

  test 'holding the role through a topic confers the privileges' do
    reader = users(:two)
    Role.seed_defaults!
    role = Role.find_by!(name: 'Audit log administrator')
    topic = TrainingTopic.create!(name: "Auditors #{SecureRandom.hex(3)}")
    TrainingTopicRole.create!(training_topic: topic, role: role, member_source: 'trained_in')
    Training.create!(trainee: reader, training_topic: topic, trained_at: Time.current)
    reader.reset_privilege_cache!

    assert reader.can?('audit_logs.manage')
    assert reader.can?('audit_logs.view_all')
    assert reader.can?('audit_logs.alerts_all')
    assert_not reader.can?('members.delete')
  end

  test 'a topic-scoped privilege applies only through its own topic' do
    reader = users(:two)
    topic = grant_privileges(reader, 'audit_logs.view')
    unrelated = TrainingTopic.create!(name: "Unrelated #{SecureRandom.hex(3)}")

    assert reader.can?('audit_logs.view', topic: topic)
    assert_not reader.can?('audit_logs.view', topic: unrelated)
    assert_not reader.can?('audit_logs.view'), 'no topic given, and the privilege is not global'
    assert reader.can_for_any_topic?('audit_logs.view')
  end

  test 'the seed migration is idempotent' do
    2.times do
      Privilege.seed_defaults!
      Role.seed_defaults!
      EmailTemplate.seed_defaults!
    end

    assert_equal 1, Role.where(name: 'Audit log administrator').count
    assert_equal 1, EmailTemplate.where(key: 'audit_log_alert').count
    assert_equal KEYS.size, Privilege.where(key: KEYS).count
  end
end
