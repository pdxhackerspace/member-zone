require 'test_helper'

class PrivilegeTest < ActiveSupport::TestCase
  test 'seeding creates the whole catalog' do
    Privilege.seed_defaults!
    catalog_keys = Privilege::CATALOG.pluck(:key)

    assert_equal catalog_keys.size, Privilege.where(key: catalog_keys).count
  end

  test 'seeding is idempotent' do
    Privilege.seed_defaults!
    before = Privilege.count
    Privilege.seed_defaults!

    assert_equal before, Privilege.count
  end

  test 'catalog keys are unique' do
    keys = Privilege::CATALOG.pluck(:key)

    assert_equal keys.uniq.size, keys.size
  end

  test 'catalog entries default to global scope' do
    Privilege.seed_defaults!

    assert_predicate Privilege.find_by(key: 'access.manage_rfids'), :global?
    assert_predicate Privilege.find_by(key: 'training.topics.manage_links'), :topic_scoped?
  end

  test 'topic scoped privileges are limited to training, documents and audit logs' do
    Privilege.seed_defaults!

    assert_equal %w[audit_logs.alerts audit_logs.view training.documents.manage training.record
                    training.respond_requests training.revoke training.subtopics.create training.subtopics.manage
                    training.topics.edit_details training.topics.manage_links],
                 Privilege.topic_scoped.order(:key).pluck(:key)
  end

  test 'scope must be recognised' do
    privilege = Privilege.new(key: 'x', label: 'X', privilege_scope: 'nonsense')

    assert_not privilege.valid?
    assert_includes privilege.errors[:privilege_scope], 'is not included in the list'
  end

  test 'keys are unique' do
    Privilege.create!(key: 'dupe.key', label: 'First')
    duplicate = Privilege.new(key: 'dupe.key', label: 'Second')

    assert_not duplicate.valid?
  end
end
