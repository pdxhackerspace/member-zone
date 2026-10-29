# frozen_string_literal: true

require 'test_helper'

class MembershipApplicationTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  test 'submit! enqueues AI feedback job' do
    app = MembershipApplication.create!(email: 'enqueue-ai-test@example.com', status: 'draft')

    assert_enqueued_with(job: MembershipApplicationAiFeedbackJob, args: [app.id]) do
      app.submit!
    end
  end

  test 'submit! emails staff who can review applications' do
    grant_privileges(users(:one), 'applications.review')
    app = MembershipApplication.create!(email: 'submit-ed-notify@example.com', status: 'draft')

    assert_difference 'ActionMailer::Base.deliveries.size', 1 do
      perform_enqueued_jobs only: ActionMailer::MailDeliveryJob do
        app.submit!
      end
    end

    assert_equal 'submitted', app.reload.status
    assert_enqueued_jobs 1, only: MembershipApplicationAiFeedbackJob
  end

  test 'delay_for_review! moves open application to under_review and journals' do
    app = MembershipApplication.create!(email: 'delay-review@example.com', status: 'submitted')
    admin = users(:one)

    assert_difference -> { Journal.where(action: 'application_delayed_for_review').count }, 1 do
      app.delay_for_review!(admin, notes: 'Need board input')
    end

    app.reload
    assert_equal 'under_review', app.status
    assert_equal admin, app.reviewed_by
    assert app.reviewed_at.present?
    assert_equal 'Need board input', app.admin_notes
  end

  test 'delay_for_review! raises when not open' do
    app = MembershipApplication.create!(email: 'delay-bad@example.com', status: 'approved',
                                        submitted_at: Time.current, reviewed_at: Time.current)

    assert_raises(ArgumentError) do
      app.delay_for_review!(users(:one))
    end
  end

  test 'mark_needs_review! moves open application to needs_review and journals' do
    app = MembershipApplication.create!(email: 'needs-review@example.com', status: 'submitted')
    admin = users(:one)

    assert_difference -> { Journal.where(action: 'application_marked_needs_review').count }, 1 do
      app.mark_needs_review!(admin, notes: 'Not now')
    end

    app.reload
    assert_equal 'needs_review', app.status
    assert_equal admin, app.reviewed_by
    assert app.reviewed_at.present?
    assert_equal 'Not now', app.admin_notes
    assert_not app.acceptance_vote_open?
  end

  test 'mark_needs_review! raises when not open' do
    app = MembershipApplication.create!(email: 'needs-review-bad@example.com', status: 'approved',
                                        submitted_at: Time.current, reviewed_at: Time.current)

    assert_raises(ArgumentError) do
      app.mark_needs_review!(users(:one))
    end
  end

  test 'stale_pending excludes applications held for review' do
    travel_to Time.zone.local(2026, 5, 28, 12, 0, 0) do
      held = %w[needs_review under_review].map do |status|
        MembershipApplication.create!(
          email: "held-#{status}@example.com",
          status: status,
          submitted_at: 8.days.ago,
          created_at: 8.days.ago,
          reviewed_at: Time.current
        )
      end

      ids = MembershipApplication.stale_pending.pluck(:id)
      held.each { |app| assert_not_includes ids, app.id }
    end
  end

  test 'under_review_apps includes needs_review status' do
    parked = MembershipApplication.create!(
      email: 'in-review-tab@example.com',
      status: 'needs_review',
      submitted_at: Time.current,
      reviewed_at: Time.current
    )

    assert_includes MembershipApplication.under_review_apps.pluck(:id), parked.id
  end

  test 'reject! creates pending queued rejection mail' do
    app = MembershipApplication.create!(email: 'reject-mail-test@example.com', status: 'submitted')
    admin = users(:one)

    qm = nil
    assert_difference 'QueuedMail.count', 1 do
      qm = app.reject!(admin, notes: 'Does not meet requirements')
    end

    assert_equal 'rejected', app.reload.status
    assert_equal 'pending', qm.status
    assert_equal 'application_rejected', qm.mailer_action
    assert_equal app.email, qm.to
    assert_equal qm.id, app.outcome_queued_mail_id
    assert_includes qm.body_html, 'Does not meet requirements'
  end

  test 'reject! queues mail to linked user email' do
    member = users(:member_with_local_account)
    app = MembershipApplication.create!(
      email: 'other@example.com',
      status: 'submitted',
      user: member
    )
    admin = users(:one)

    qm = app.reject!(admin, notes: nil)

    assert_equal member.email, qm.to
    assert_equal member, qm.recipient
  end

  test 'stale_pending includes pending applications older than one week' do
    travel_to Time.zone.local(2026, 5, 28, 12, 0, 0) do
      stale = MembershipApplication.create!(
        email: 'stale-pending@example.com',
        status: 'submitted',
        submitted_at: 8.days.ago,
        created_at: 8.days.ago
      )
      recent = MembershipApplication.create!(
        email: 'recent-pending@example.com',
        status: 'under_review',
        submitted_at: 2.days.ago,
        created_at: 2.days.ago
      )
      approved = MembershipApplication.create!(
        email: 'old-approved@example.com',
        status: 'approved',
        submitted_at: 10.days.ago,
        created_at: 10.days.ago
      )

      ids = MembershipApplication.stale_pending.pluck(:id)
      assert_includes ids, stale.id
      assert_not_includes ids, recent.id
      assert_not_includes ids, approved.id
    end
  end

  test 'newest_first orders by submitted time (fallback created_at), then id desc' do
    travel_to Time.zone.local(2026, 4, 15, 12, 0, 0) do
      older = MembershipApplication.create!(
        email: 'order-old@example.com', status: 'submitted',
        submitted_at: 5.days.ago, created_at: 5.days.ago
      )
      newer = MembershipApplication.create!(
        email: 'order-new@example.com', status: 'submitted',
        submitted_at: 1.day.ago, created_at: 2.days.ago
      )
      ids = MembershipApplication.where(id: [older.id, newer.id]).newest_first.pluck(:id)
      assert_equal [newer.id, older.id], ids

      t = Time.current
      first = MembershipApplication.create!(
        email: 'tie-a@example.com', status: 'submitted', submitted_at: t, created_at: t
      )
      second = MembershipApplication.create!(
        email: 'tie-b@example.com', status: 'submitted', submitted_at: t, created_at: t
      )
      assert_operator second.id, :>, first.id
      tie_ids = MembershipApplication.where(id: [first.id, second.id]).newest_first.pluck(:id)
      assert_equal [second.id, first.id], tie_ids
    end
  end

  test 'admin_search matches email, answer text, and linked member fields' do
    page = ApplicationFormPage.create!(title: 'Search Page', position: 9988)
    q_bio = page.questions.create!(label: 'Bio', field_type: 'textarea', required: false, position: 1)

    by_email = MembershipApplication.create!(email: 'unique-sapphire@example.com', status: 'submitted')
    by_answer = MembershipApplication.create!(email: 'plain@example.com', status: 'submitted')
    by_answer.application_answers.create!(application_form_question: q_bio, value: 'unique-quasar-hobby')
    other = MembershipApplication.create!(email: 'other@example.com', status: 'submitted')

    ids = MembershipApplication.admin_search('unique-sapphire@example.com').pluck(:id)
    assert_includes ids, by_email.id
    assert_not_includes ids, other.id

    ids = MembershipApplication.admin_search('unique-quasar').pluck(:id)
    assert_includes ids, by_answer.id
    assert_not_includes ids, other.id

    member = users(:member_with_local_account)
    linked = MembershipApplication.create!(email: 'x@example.com', status: 'submitted', user: member)
    ids = MembershipApplication.admin_search('regularmember').pluck(:id)
    assert_includes ids, linked.id
  end

  test 'applicant_display_name uses name answer, linked user, or em dash' do
    page = ApplicationFormPage.create!(title: 'Test Contact', position: 9999)
    q = page.questions.create!(label: 'Name', field_type: 'text', required: false, position: 1)
    app = MembershipApplication.create!(email: 'applicant-name-test@example.com', status: 'submitted')

    assert_equal '—', app.applicant_display_name(name_question_id: q.id)

    app.application_answers.create!(application_form_question: q, value: '  Jane Doe  ')
    assert_equal 'Jane Doe', app.reload.applicant_display_name(name_question_id: q.id)

    app.application_answers.destroy_all
    member = users(:member_with_local_account)
    app.update!(user: member)
    assert_equal member.display_name, app.reload.applicant_display_name(name_question_id: q.id)
  end

  test 'ai_feedback_admin_vote_counts groups by stance with ordered association' do
    app = MembershipApplication.create!(email: 'vote-counts@example.com', status: 'submitted')
    MembershipApplicationAiFeedbackVote.create!(
      membership_application: app,
      user: users(:one),
      stance: 'agree'
    )
    MembershipApplicationAiFeedbackVote.create!(
      membership_application: app,
      user: users(:two),
      stance: 'disagree'
    )
    counts = app.reload.ai_feedback_admin_vote_counts
    assert_equal 1, counts['agree']
    assert_equal 1, counts['disagree']
  end

  test 'ai_feedback_recommendation_badge_color maps known recommendations' do
    app = MembershipApplication.new
    app.ai_feedback_recommendation = 'accept'
    assert_equal 'success', app.ai_feedback_recommendation_badge_color
    app.ai_feedback_recommendation = 'reject'
    assert_equal 'danger', app.ai_feedback_recommendation_badge_color
    app.ai_feedback_recommendation = 'needs_review'
    assert_equal 'warning', app.ai_feedback_recommendation_badge_color
    app.ai_feedback_recommendation = 'something_else'
    assert_equal 'secondary', app.ai_feedback_recommendation_badge_color
  end

  test 'processing_time_stats averages finalized applications since cutoff' do
    travel_to Time.zone.local(2026, 6, 19, 12, 0, 0) do
      since = Time.zone.local(2026, 4, 19, 12, 0, 0)
      opened_at = Time.zone.local(2026, 4, 20, 12, 0, 0)
      MembershipApplication.create!(
        email: 'processed-fast@example.com',
        status: 'approved',
        submitted_at: opened_at,
        reviewed_at: opened_at + 1.day
      )
      MembershipApplication.create!(
        email: 'processed-slow@example.com',
        status: 'rejected',
        submitted_at: opened_at,
        reviewed_at: opened_at + 3.days
      )
      MembershipApplication.create!(
        email: 'still-open@example.com',
        status: 'submitted',
        submitted_at: opened_at
      )
      MembershipApplication.create!(
        email: 'parked-review@example.com',
        status: 'needs_review',
        submitted_at: opened_at,
        reviewed_at: opened_at + 1.day
      )
      MembershipApplication.create!(
        email: 'processed-old@example.com',
        status: 'approved',
        submitted_at: since - 10.days,
        reviewed_at: since - 1.day
      )

      stats = MembershipApplications::ProcessingTimeStats.call(since: since)

      assert_equal 2, stats[:count]
      assert_in_delta 2.days.to_i, stats[:average_seconds], 1.0
      assert_equal '2 days', stats[:average_label]
    end
  end

  test 'processing_time_stats returns empty stats when no finalized applications' do
    travel_to Time.zone.local(2026, 6, 19, 12, 0, 0) do
      stats = MembershipApplications::ProcessingTimeStats.call(since: 1.month.ago)

      assert_equal 0, stats[:count]
      assert_nil stats[:average_seconds]
      assert_nil stats[:average_label]
    end
  end

  test 'status_page_verification returns newest verification for email' do
    app = MembershipApplication.create!(
      email: 'status-page-verification@example.com',
      status: 'submitted',
      submitted_at: Time.current
    )
    older = ApplicationVerification.create!(email: app.email, created_at: 2.days.ago)
    newer = ApplicationVerification.create!(email: app.email, created_at: 1.day.ago)

    assert_equal newer.id, app.status_page_verification.id
    assert_not_equal older.id, app.status_page_verification.id
  end

  test 'status_page_verification is nil for draft applications' do
    app = MembershipApplication.create!(email: 'draft-no-status@example.com', status: 'draft')
    ApplicationVerification.create!(email: app.email)

    assert_nil app.status_page_verification
  end
end
