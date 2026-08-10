require 'test_helper'

class UserSponsoredTest < ActiveSupport::TestCase
  # ─── Scope ─────────────────────────────────────────────────────────

  test 'is_sponsored scope returns only sponsored users' do
    sponsored = create_user(is_sponsored: true)
    regular = create_user(is_sponsored: false)

    assert_includes User.is_sponsored, sponsored
    assert_not_includes User.is_sponsored, regular
  end

  test 'is_sponsored defaults to false' do
    user = User.new(authentik_id: 'sp-default', full_name: 'Default Test', payment_type: 'unknown')
    assert_not user.is_sponsored?
  end

  # ─── Access ────────────────────────────────────────────────────────
  #
  # Sponsorship is a membership state, not a flag layered over one. mark_sponsored! sets
  # both, so the flag and the state move together.

  test 'sponsoring a member activates them whatever their dues history' do
    user = create_user(membership_state: 'inactive_member')

    user.mark_sponsored!

    assert user.active?
    assert user.is_sponsored?
    assert_equal 'sponsored_member', user.membership_state
  end

  test 'a sponsored member has no dues to fall behind on' do
    user = create_user(membership_state: 'sponsored_member', last_payment_date: 3.years.ago.to_date)

    assert user.active?
    assert_equal 'current', user.dues_status
  end

  test 'ending a sponsorship re-evaluates access' do
    user = create_user(membership_state: 'sponsored_member')
    assert user.active?

    user.unmark_sponsored!

    assert_not user.active?, 'with no payment history there is nothing left to keep them active'
    assert_not user.is_sponsored?
  end

  test 'ending a sponsorship keeps a member whose payments are current' do
    user = create_user(membership_state: 'sponsored_member', last_payment_date: Date.current)

    user.unmark_sponsored!

    assert user.active?
    assert_equal 'current_member', user.membership_state
  end

  # Somebody else covers a sponsored member, so 'sponsored' is their payment type rather
  # than a gap in our records. Leaving it unknown put them in the report for members
  # nobody is billing by accident.
  test 'a sponsored member pays by sponsorship' do
    user = create_user(membership_state: 'sponsored_member')

    assert_equal 'sponsored', user.payment_type
  end

  test 'the payment type follows the state even when set by hand' do
    user = create_user(membership_state: 'sponsored_member')

    user.update!(payment_type: 'unknown')

    assert_equal 'sponsored', user.reload.payment_type
  end

  # A sponsored member turning up in a PayPal sync has not started paying their own
  # dues — the sponsorship is still what covers them.
  test 'a linked payment does not take the sponsorship over' do
    user = create_user(membership_state: 'sponsored_member')
    user.paypal_payments.create!(paypal_id: "PP-#{SecureRandom.hex(4)}", transaction_time: 1.day.ago,
                                 amount: 40.0, currency: 'USD', status: 'Completed')

    assert_equal 'sponsored', user.reload.payment_type
    assert_equal 'sponsored_member', user.membership_state
  end

  test 'a deceased member is inactive even when sponsored' do
    user = create_user(membership_state: 'sponsored_member', payment_type: 'paypal')

    user.mark_deceased!

    assert_not user.active?, 'deceased member should be inactive even when sponsored'
    assert_equal 'inactive', user.payment_type
  end

  # ─── Journal entry for sponsorship ─────────────────────────────────

  test 'manually marking as sponsored creates a journal entry' do
    user = create_user(is_sponsored: false)
    initial_count = user.journals.count

    user.update!(is_sponsored: true)

    assert_operator user.journals.count, :>, initial_count,
                    'Manual sponsorship should create a journal entry'
  end

  test 'removing sponsorship creates a journal entry' do
    user = create_user(is_sponsored: true)
    initial_count = user.journals.count

    user.update!(is_sponsored: false)

    assert_operator user.journals.count, :>, initial_count,
                    'Removing sponsorship should create a journal entry'
  end

  private

  def create_user(attrs = {})
    defaults = {
      authentik_id: "sponsored-test-#{SecureRandom.hex(4)}",
      full_name: "Sponsored Test #{SecureRandom.hex(4)}",
      payment_type: 'unknown',
      is_sponsored: false
    }
    User.create!(defaults.merge(attrs))
  end
end
