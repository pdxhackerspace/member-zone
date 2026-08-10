require 'test_helper'

class MembershipActiveReconcilerTest < ActiveSupport::TestCase
  test 'preview lists stale users without saving' do
    user = User.create!(
      authentik_id: 'reconcile-preview',
      full_name: 'Stale Preview',
      membership_state: 'banned_member',
      payment_type: 'unknown'
    )
    user.update_columns(active: true)

    assert_no_changes -> { user.reload.active } do
      assert_output(/Stale Preview/) do
        MembershipActiveReconciler.new(dry_run: true, scope: User.where(id: user.id)).run
      end
    end
  end

  test 'reconcile fixes stale users' do
    user = User.create!(
      authentik_id: 'reconcile-apply',
      full_name: 'Stale Apply',
      membership_state: 'banned_member',
      payment_type: 'unknown'
    )
    user.update_columns(active: true)

    MembershipActiveReconciler.new(dry_run: false, scope: User.where(id: user.id)).run

    assert_not user.reload.active
  end
end
