require 'test_helper'

# While a request is authenticated by an API token, its holder's privileges are limited to the
# token's scopes everywhere they are checked, and administrators lose their shortcuts.
class UserApiTokenScopeTest < ActiveSupport::TestCase
  setup do
    @admin = users(:one)
    @admin.update_columns(is_admin: true)
    @token = ApiToken.create!(user: @admin, created_by: @admin, name: 'Admin script',
                              scopes: ['parking.manage_notices'])
  end

  teardown do
    Current.reset
  end

  test 'without a token, an administrator can do anything' do
    assert @admin.can?('members.delete')
    assert @admin.admin?
  end

  test 'acting through a token, only its scopes apply and admin? is false' do
    Current.api_token = @token

    assert @admin.acting_through_api_token?
    assert @admin.can?('parking.manage_notices')
    assert_not @admin.can?('members.delete')
    assert_not @admin.admin?
    assert @admin.is_admin?
  end

  test 'the scope limit applies only to the token holder' do
    other = users(:two)
    grant_privileges(other, 'members.delete')
    Current.api_token = @token

    assert_not other.acting_through_api_token?
    assert other.can?('members.delete')
  end

  test 'a scoped privilege still has to be held' do
    member = users(:two)
    grant_privileges(member, 'api.users.search')
    token = ApiToken.create!(user: member, created_by: member, name: 'Search', scopes: ['api.users.search'])
    Training.where(trainee: member).destroy_all
    member.reset_privilege_cache!
    Current.api_token = token

    assert_not member.can?('api.users.search')
  end

  test 'history entries record the token they came in through' do
    Current.api_token = @token
    event = parking_notices(:active_permit).log_event!('note', actor: @admin, note: 'via API')

    assert_equal @token, event.api_token
  end
end
