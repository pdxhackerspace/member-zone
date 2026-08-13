require 'test_helper'

class MembershipStateHelperTest < ActionView::TestCase
  include MembershipStateHelper

  # The membership card's renewal line is wrong for someone who cancelled: the subscription
  # will not renew, and showing the date as a payment — worse, as an overdue one — asks
  # them for money they already told us they were done paying.
  test 'a cancelled member still covered by their payment sees when access ends' do
    access_until = 45.days.from_now
    user = member(state: 'cancelled_member', dues_due_at: access_until)

    phrase, note = member_cancellation_line(user)

    assert_equal "Active until #{access_until.strftime('%b %-d')}", phrase
    assert_equal 'in 45 days', note
  end

  test 'a cancellation whose date has passed reads as ended' do
    access_until = 3.months.ago
    user = member(state: 'inactive_member', dues_due_at: access_until)

    phrase, note = member_cancellation_line(user)

    assert_equal "Ended #{access_until.strftime('%b %-d')}", phrase
    assert_nil note
  end

  test 'a cancellation in a previous year is dated with the year' do
    access_until = 2.years.ago
    user = member(state: 'inactive_member', dues_due_at: access_until)

    assert_equal "Ended #{access_until.strftime('%b %-d, %Y')}", member_cancellation_line(user).first
  end

  test 'a cancelled member with nothing counting down says so rather than inventing a date' do
    user = member(state: 'cancelled_member', dues_due_at: nil)

    assert_equal ['No end date on record', nil], member_cancellation_line(user)
  end

  # The card falls back to its ordinary renewal line when there is no cancellation to show.
  test 'a paying member gets no cancellation line' do
    assert_nil member_cancellation_line(member(state: 'current_member', dues_due_at: 1.month.from_now))
  end

  test 'a member who lapsed without cancelling gets no cancellation line' do
    user = member(state: 'inactive_member', dues_due_at: 2.months.ago)
    user.update_columns(membership_cancelled_at: nil)

    assert_nil member_cancellation_line(user.reload)
  end

  # A sponsorship granted after the fact says more about where they stand than the notice.
  test 'a cancellation superseded by a sponsorship is not shown' do
    user = member(state: 'cancelled_member', dues_due_at: 1.month.from_now)
    user.mark_sponsored!

    assert_predicate user, :cancellation_recorded?
    assert_nil member_cancellation_line(user)
  end

  private

  def member(state:, dues_due_at:)
    user = User.create!(
      authentik_id: "card-#{SecureRandom.hex(4)}",
      full_name: 'Card Member',
      email: "card-#{SecureRandom.hex(4)}@example.com",
      payment_type: 'recharge',
      membership_state: state,
      dues_due_at: dues_due_at
    )
    user.update_columns(membership_cancelled_at: 1.month.ago) if state.in?(%w[cancelled_member inactive_member])
    user.reload
  end
end
