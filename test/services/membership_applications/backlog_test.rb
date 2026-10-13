require 'test_helper'

module MembershipApplications
  class BacklogTest < ActiveSupport::TestCase
    setup do
      MembershipSetting.instance.update!(application_backlog_overdue_days: 7)
    end

    test 'splits pending applications into recent, overdue, and held' do
      create_app('recent@example.com', 'submitted', submitted_at: 3.days.ago)
      create_app('edge@example.com', 'submitted', submitted_at: 7.days.ago + 1.minute)
      create_app('overdue@example.com', 'submitted', submitted_at: 8.days.ago)
      create_app('parked@example.com', 'under_review', submitted_at: 30.days.ago)
      create_app('needs@example.com', 'needs_review', submitted_at: 1.day.ago)
      create_app('draft@example.com', 'draft')
      create_app('approved@example.com', 'approved', submitted_at: 20.days.ago)

      backlog = Backlog.call

      assert_equal 2, backlog.recent
      assert_equal 1, backlog.overdue
      assert_equal 2, backlog.held
      assert_equal MembershipApplication.pending.count, backlog.total
    end

    test 'falls back to created_at when submitted_at is missing' do
      app = create_app('imported@example.com', 'submitted')
      app.update_columns(created_at: 10.days.ago)

      assert_equal 1, Backlog.call.overdue
    end

    test 'uses the configured overdue threshold' do
      create_app('four@example.com', 'submitted', submitted_at: 4.days.ago)
      MembershipSetting.instance.update!(application_backlog_overdue_days: 3)

      backlog = Backlog.call

      assert_equal 0, backlog.recent
      assert_equal 1, backlog.overdue
      assert_equal 3, backlog.overdue_days
    end

    test 'is empty when nothing is pending' do
      assert_predicate Backlog.call, :empty?
    end

    test 'filter_by_age narrows open applications' do
      recent = create_app('r@example.com', 'submitted', submitted_at: 1.day.ago)
      overdue = create_app('o@example.com', 'submitted', submitted_at: 9.days.ago)
      scope = MembershipApplication.submitted_apps

      assert_equal [recent], Backlog.filter_by_age(scope, 'recent').to_a
      assert_equal [overdue], Backlog.filter_by_age(scope, 'overdue').to_a
      assert_equal 2, Backlog.filter_by_age(scope, nil).count
    end

    private

    def create_app(email, status, submitted_at: nil)
      MembershipApplication.create!(email:, status:, submitted_at:)
    end
  end
end
