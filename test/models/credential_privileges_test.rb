require 'test_helper'

class CredentialPrivilegesTest < ActiveSupport::TestCase
  KEYS = %w[credentials.manage_providers credentials.view_all credentials.issue_for_members credentials.revoke].freeze

  setup { Privilege.seed_defaults! }

  test 'the catalog defines the four credential privileges, in their own category' do
    entries = Privilege::CATALOG.select { |entry| entry[:key].start_with?('credentials.') }

    assert_equal KEYS.sort, entries.pluck(:key).sort
    assert_equal ['Credentials'], entries.pluck(:category).uniq
  end

  test 'they are all global' do
    assert_equal ['global'], Privilege.where(key: KEYS).pluck(:privilege_scope).uniq
  end

  test 'seeding creates a Credentials administrator role holding all four' do
    Role.seed_defaults!

    assert_equal KEYS.sort, Role.find_by!(name: 'Credentials administrator').privilege_keys.sort
  end

  test 'requesting your own credential needs no privilege' do
    assert_not_includes KEYS, 'credentials.request'
  end

  test 'an administrator holds them all' do
    admin = users(:one)
    admin.update_columns(is_admin: true)

    KEYS.each { |key| assert admin.can?(key), key }
  end

  test 'a plain member holds none of them' do
    KEYS.each { |key| assert_not users(:two).can?(key), key }
  end

  test 'a member holds one only by way of a role on a topic they hold' do
    member = create_member
    grant_privileges(member, 'credentials.revoke')

    assert member.reload.can?('credentials.revoke')
    assert_not member.can?('credentials.view_all')
  end

  test 'the seed migration is idempotent' do
    assert_nothing_raised do
      Privilege.seed_defaults!
      Role.seed_defaults!
      EmailTemplate.seed_defaults!
    end
    assert_equal 1, Role.where(name: 'Credentials administrator').count
    assert_equal 1, EmailTemplate.where(key: 'credentials_revoked').count
  end

  test 'the three email templates are seeded' do
    EmailTemplate.seed_defaults!

    assert_equal 3, EmailTemplate.where(key: %w[credential_expiring_soon credential_expired credentials_revoked]).count
  end
end
