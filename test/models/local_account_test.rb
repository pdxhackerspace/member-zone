require 'test_helper'

class LocalAccountTest < ActiveSupport::TestCase
  test 'requires a unique email' do
    existing = local_accounts(:active_admin)
    duplicate = LocalAccount.new(email: existing.email, password: 'anotherpassword123')

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:email], 'has already been taken'
  end

  # Sign-in accounts, so the duplicate the validation cannot see must not reach the table:
  # encryption left the email column unable to catch it, which leaves the digest index.
  test 'the database refuses a second account holding the same address' do
    LocalAccount.create!(email: 'contested@example.com', password: 'firstpassword123')
    duplicate = LocalAccount.new(email: 'contested@example.com', password: 'anotherpassword123')
    duplicate.validate # fills in the digest the way a racing create would

    assert_raises ActiveRecord::RecordNotUnique do
      duplicate.save!(validate: false)
    end
  end

  # Seeding and bin/dev-db-restore both re-run against databases that already hold the
  # account. Looking it up on the encrypted column matched nothing, so they built a duplicate
  # the digest index refused, and the restore died on its last step.
  test 'provisioning twice updates the account rather than duplicating it' do
    first = LocalAccount.provision!(email: 'bootstrap@example.com', password: 'bootstrappass123',
                                    full_name: 'Bootstrap Admin')

    second = assert_no_difference -> { LocalAccount.count } do
      LocalAccount.provision!(email: 'bootstrap@example.com', password: 'rotatedpassword123',
                              full_name: 'Bootstrap Admin')
    end

    assert_equal first.id, second.id
    assert second.reload.authenticate('rotatedpassword123')
  end

  test 'provisioning finds the account it already encrypted' do
    existing = local_accounts(:active_admin)

    provisioned = LocalAccount.provision!(email: existing.email.upcase, password: 'freshpassword123')

    assert_equal existing.id, provisioned.id
  end

  test 'an account encrypted under another key is reported as unreadable' do
    account = local_accounts(:regular_member)
    readable = local_accounts(:active_admin)
    account.update_columns(email: "#{SensitiveData::STRING_PREFIX}not-ciphertext-from-this-key")

    assert_not account.reload.email_readable?
    assert_predicate readable, :email_readable?
    assert_includes LocalAuth::UnreadableAccounts.ids, account.id
    assert_not_includes LocalAuth::UnreadableAccounts.ids, readable.id
  end

  test 'enforces minimum password length' do
    account = LocalAccount.new(email: 'new@example.com', password: 'short')

    assert_not account.valid?
    assert_includes account.errors[:password], 'is too short (minimum is 12 characters)'
  end
end
