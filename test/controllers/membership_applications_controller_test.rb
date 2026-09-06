# frozen_string_literal: true

# Also see MembershipApplicationTest for admin_search scope tests and index?q tests below.
require 'test_helper'
require 'active_job/test_helper'

class MembershipApplicationsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true
    sign_in_as_admin
    @page = ApplicationFormPage.create!(title: 'Controller Import Page', position: 901)
    @page.questions.create!(label: 'Name', field_type: 'text', required: false, position: 1)
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  test 'import creates membership application from csv' do
    file = fixture_file_upload('membership_application_import.csv', 'text/csv')

    assert_difference('MembershipApplication.count', 1) do
      post import_membership_applications_path, params: { file: file }
    end

    assert_redirected_to membership_applications_path
    follow_redirect!
    assert_match(/Imported 1 application/, flash[:notice])

    app = MembershipApplication.by_email('controller-csv-import@example.com').first!
    assert_equal 'approved', app.status
    assert_equal 'Sam Sample', app.answer_for(@page.questions.first)&.value
  end

  test 'import without file redirects with alert' do
    post import_membership_applications_path
    assert_redirected_to membership_applications_path
    assert_equal 'Please choose a CSV file to import.', flash[:alert]
  end

  test 'non-admin cannot view membership application show' do
    app = MembershipApplication.create!(
      email: 'non-admin-denied@example.com',
      status: 'submitted',
      submitted_at: Time.current
    )

    delete logout_path
    account = local_accounts(:regular_member)
    post local_login_path, params: {
      session: { email: account.email, password: 'memberpassword123' }
    }

    get membership_application_path(app)

    assert_redirected_to user_path(users(:member_with_local_account))
    assert_equal 'You do not have access to that section.', flash[:alert]
  end

  test 'link_user associates member with application' do
    app = MembershipApplication.create!(
      email: 'link-app-test@example.com',
      status: 'approved',
      submitted_at: Time.current,
      reviewed_at: Time.current
    )
    member = users(:member_with_local_account)

    post link_user_membership_application_path(app), params: { user_id: member.id }

    assert_redirected_to membership_application_path(app)
    assert_match(/linked/i, flash[:notice])
    assert_equal member.id, app.reload.user_id
  end

  test 'link_user rejects open and under-review applications' do
    app = MembershipApplication.create!(
      email: 'link-pending@example.com',
      status: 'submitted',
      submitted_at: Time.current
    )
    member = users(:member_with_local_account)

    post link_user_membership_application_path(app), params: { user_id: member.id }

    assert_redirected_to membership_application_path(app)
    assert_match(/cannot be linked/i, flash[:alert])
    assert_nil app.reload.user_id
  end

  test 'index open tab does not offer link member action' do
    MembershipApplication.create!(
      email: 'open-no-link@example.com',
      status: 'submitted',
      submitted_at: Time.current
    )

    get membership_applications_path(status: 'submitted')

    assert_response :success
    assert_select 'button', text: 'Link member', count: 0
  end

  test 'index shows average processing time for finalized applications' do
    travel_to Time.zone.local(2026, 6, 19, 12, 0, 0) do
      since = 1.month.ago
      MembershipApplication.create!(
        email: 'index-stats@example.com',
        status: 'approved',
        submitted_at: since + 1.day,
        reviewed_at: since + 3.days
      )

      get membership_applications_path

      assert_response :success
      assert_select '.text-13', text: /Average processing time \(last month\):/
      assert_select '.text-13', text: /2 days/
      assert_select '.text-13', text: /1 approved or rejected/
    end
  end

  test 'index under review tab does not offer link member action' do
    MembershipApplication.create!(
      email: 'review-no-link@example.com',
      status: 'under_review',
      submitted_at: Time.current
    )

    get membership_applications_path(status: 'under_review')

    assert_response :success
    assert_select 'button', text: 'Link member', count: 0
  end

  test 'index unlinked tab offers link member action' do
    app = MembershipApplication.create!(
      email: 'unlinked-linkable@example.com',
      status: 'approved',
      submitted_at: Time.current,
      reviewed_at: Time.current
    )

    get membership_applications_path(status: 'unlinked')

    assert_response :success
    assert_select 'button', text: 'Link member'
    assert_select 'button[data-ma-link-action=?]', link_user_membership_application_path(app)
  end

  test 'index and show link to applicant status page when verification exists' do
    verification = ApplicationVerification.create!(
      email: 'admin-status-link@example.com',
      confirmed_open_house: true,
      confirmed_code_of_conduct: true,
      email_verified: true,
      verified_at: Time.current
    )
    app = MembershipApplication.create!(
      email: 'admin-status-link@example.com',
      status: 'submitted',
      submitted_at: Time.current
    )
    status_path = apply_application_status_path(token: verification.token)

    get membership_applications_path(status: 'submitted')

    assert_response :success
    assert_select 'a[href=?][target=_blank]', status_path, text: 'Applicant view'

    get membership_application_path(app)

    assert_response :success
    assert_select 'a[href=?][target=_blank]', status_path, text: 'Applicant status'
  end

  test 'index search filters by query param' do
    q_page = ApplicationFormPage.create!(title: 'Idx Search Page', position: 9989)
    qq = q_page.questions.create!(label: 'Note', field_type: 'text', required: false, position: 1)
    hit = MembershipApplication.create!(
      email: 'idx-search-hit@example.com', status: 'submitted', submitted_at: Time.current
    )
    hit.application_answers.create!(application_form_question: qq, value: 'idx-unique-needle')
    miss = MembershipApplication.create!(
      email: 'idx-search-miss@example.com', status: 'submitted', submitted_at: Time.current
    )

    get membership_applications_path(q: 'idx-unique-needle')

    assert_response :success
    assert_select 'a[href=?]', membership_application_path(hit)
    assert_select 'a[href=?]', membership_application_path(miss), count: 0
  end

  test 'index defaults to open submitted tab' do
    open_app = MembershipApplication.create!(
      email: 'default-open@example.com',
      status: 'submitted',
      submitted_at: Time.current
    )
    closed_app = MembershipApplication.create!(
      email: 'default-approved@example.com',
      status: 'approved',
      submitted_at: Time.current,
      reviewed_at: Time.current
    )

    get membership_applications_path

    assert_response :success
    assert_select 'a.nav-link.active', text: /Open/
    assert_select 'a[href=?]', membership_application_path(open_app)
    assert_select 'a[href=?]', membership_application_path(closed_app), count: 0
  end

  test 'index unlinked tab lists only approved applications without a linked member' do
    linked_member = users(:member_with_local_account)
    keep = MembershipApplication.create!(
      email: 'unlinked-approved@example.com',
      status: 'approved',
      submitted_at: Time.current,
      reviewed_at: Time.current
    )
    filtered_open = MembershipApplication.create!(
      email: 'unlinked-open@example.com',
      status: 'submitted',
      submitted_at: Time.current
    )
    filtered_rejected = MembershipApplication.create!(
      email: 'unlinked-rejected@example.com',
      status: 'rejected',
      submitted_at: Time.current,
      reviewed_at: Time.current
    )
    filtered_linked = MembershipApplication.create!(
      email: 'linked-approved@example.com',
      status: 'approved',
      submitted_at: Time.current,
      reviewed_at: Time.current,
      user: linked_member
    )

    get membership_applications_path(status: 'unlinked')

    assert_response :success
    assert_select 'a.nav-link.active', text: /Unlinked/
    assert_select 'a[href=?]', membership_application_path(keep)
    assert_select 'a[href=?]', membership_application_path(filtered_open), count: 0
    assert_select 'a[href=?]', membership_application_path(filtered_rejected), count: 0
    assert_select 'a[href=?]', membership_application_path(filtered_linked), count: 0
  end

  test 'index unlinked count includes only approved without a linked member' do
    MembershipApplication.create!(
      email: 'badge-open-unlinked@example.com',
      status: 'submitted',
      submitted_at: Time.current
    )
    MembershipApplication.create!(
      email: 'badge-approved-unlinked@example.com',
      status: 'approved',
      submitted_at: Time.current,
      reviewed_at: Time.current
    )
    MembershipApplication.create!(
      email: 'badge-rejected-unlinked@example.com',
      status: 'rejected',
      submitted_at: Time.current,
      reviewed_at: Time.current
    )

    get membership_applications_path(status: 'all')

    assert_response :success
    expected_count = MembershipApplication.where(status: 'approved').where(user_id: nil).count
    assert_select "a[href='#{membership_applications_path(status: 'unlinked')}'] span.badge",
                  text: expected_count.to_s
  end

  # Asserted against the raw body rather than with assert_select: the mask this replaced was
  # a CSS blur, so the addresses were in the page the whole time and only a body assertion
  # would have caught it.
  test 'show withholds applicant contact from a reviewer without the view_pii privilege' do
    reviewer = sign_in_as_reviewer
    grant_privileges(reviewer, 'applications.view')
    app = membership_application_with_sensitive_answers
    get membership_application_path(app)

    assert_response :success
    assert_no_match(/pii-test@example\.com/, response.body)
    assert_no_match(/123 Secret Street/, response.body)
    assert_no_match(/555-000-1111/, response.body)
    assert_no_match(/referrer@example\.com/, response.body)
    assert_no_match(/555-222-3333/, response.body)
    assert_no_match(/sensitive-reveal/, response.body)
    assert_includes response.body, 'Hidden'
  end

  test 'show sends applicant contact to a reviewer holding view_pii' do
    reviewer = sign_in_as_reviewer
    grant_privileges(reviewer, 'applications.view', 'applications.view_pii')
    app = membership_application_with_sensitive_answers
    get membership_application_path(app)

    assert_response :success
    assert_match(/pii-test@example\.com/, response.body)
    assert_match(/123 Secret Street/, response.body)
  end

  test 'the application list withholds applicant emails without view_pii' do
    reviewer = sign_in_as_reviewer
    grant_privileges(reviewer, 'applications.view', 'applications.link_member')
    membership_application_with_sensitive_answers

    get membership_applications_path(status: 'all')

    assert_response :success
    # The link-member button used to carry the address in a data attribute.
    assert_no_match(/pii-test@example\.com/, response.body)
  end

  test 'show link modal withholds applicant email without view_pii' do
    reviewer = sign_in_as_reviewer
    grant_privileges(reviewer, 'applications.view', 'applications.link_member')
    app = MembershipApplication.create!(
      email: 'masked-show-link-modal@example.com',
      status: 'approved',
      submitted_at: Time.current,
      reviewed_at: Time.current
    )

    get membership_application_path(app)

    assert_response :success
    assert_no_match(/masked-show-link-modal@example\.com/, response.body)
    assert_includes response.body, 'Hidden'
  end

  test 'show does not mask for a reviewer holding view_pii' do
    reviewer = sign_in_as_reviewer
    grant_privileges(reviewer, 'applications.view', 'applications.view_pii')
    app = membership_application_with_sensitive_answers
    get membership_application_path(app)

    assert_response :success
    assert_no_match(/data-controller="sensitive-reveal"/, response.body)
  end

  test 'show does not mask for admins' do
    sign_in_as_admin
    app = membership_application_with_sensitive_answers
    get membership_application_path(app)

    assert_response :success
    assert_no_match(/data-controller="sensitive-reveal"/, response.body)
  end

  # Authorization follows the account being viewed as, so impersonating a member who cannot
  # reach the application queue shows what that member would get: nothing.
  test 'impersonating a member without applications.view cannot open an application' do
    sign_in_as_admin
    post impersonate_user_path(users(:one).id)
    app = membership_application_with_sensitive_answers

    get membership_application_path(app)

    assert_response :redirect
  end

  # An administrator holds view_pii through the admin bypass, so this is the case that
  # proves impersonation reaches the redaction and not just the navigation.
  test 'impersonating a reviewer without view_pii withholds contact details' do
    sign_in_as_admin
    reviewer = users(:one)
    grant_privileges(reviewer, 'applications.view')
    post impersonate_user_path(reviewer.id)
    app = membership_application_with_sensitive_answers

    get membership_application_path(app)

    assert_response :success
    assert_no_match(/pii-test@example\.com/, response.body)
    assert_includes response.body, 'Hidden'
  end

  test 'index link modal masks applicant email for a reviewer without view_pii' do
    reviewer = sign_in_as_reviewer
    grant_privileges(reviewer, 'applications.view', 'applications.link_member')
    app = MembershipApplication.create!(
      email: 'masked-link-modal@example.com',
      status: 'approved',
      submitted_at: Time.current,
      reviewed_at: Time.current
    )

    get membership_applications_path(status: 'unlinked')

    assert_response :success
    assert_select 'button[data-ma-link-action=?]', link_user_membership_application_path(app)
    assert_select "button[data-application-email='#{app.email}']", count: 0
    assert_no_match(/masked-link-modal@example\.com/, response.body)
    assert_includes response.body, 'Hidden'
  end

  test 'index link modal includes applicant email for a reviewer holding view_pii' do
    reviewer = sign_in_as_reviewer
    grant_privileges(reviewer, 'applications.view', 'applications.link_member', 'applications.view_pii')
    app = MembershipApplication.create!(
      email: 'visible-link-modal@example.com',
      status: 'approved',
      submitted_at: Time.current,
      reviewed_at: Time.current
    )

    get membership_applications_path(status: 'unlinked')

    assert_response :success
    assert_select 'button[data-application-email=?]', app.email
    assert_match(/visible-link-modal@example\.com/, response.body)
  end

  test 'vote_ai_feedback creates vote when AI feedback processed' do
    sign_in_as_admin
    app = MembershipApplication.create!(
      email: 'vote-ai@example.com',
      status: 'submitted',
      submitted_at: Time.current,
      ai_feedback_processed_at: Time.current,
      ai_feedback_recommendation: 'accept'
    )
    assert_difference -> { app.reload.ai_feedback_votes.count }, 1 do
      post vote_ai_feedback_membership_application_path(app), params: {
        ai_feedback_vote: { stance: 'agree', reason: 'Matches my read' }
      }
    end
    assert_redirected_to membership_application_path(app)
    vote = app.ai_feedback_votes.last
    assert_equal 'agree', vote.stance
    assert_equal 'Matches my read', vote.reason
  end

  test 'vote_ai_feedback updates existing vote for same admin' do
    sign_in_as_admin
    admin = User.find(session[:user_id])
    app = MembershipApplication.create!(
      email: 'vote-update@example.com',
      status: 'submitted',
      submitted_at: Time.current,
      ai_feedback_processed_at: Time.current,
      ai_feedback_recommendation: 'reject'
    )
    MembershipApplicationAiFeedbackVote.create!(
      membership_application: app,
      user: admin,
      stance: 'agree',
      reason: 'First'
    )
    assert_no_difference -> { app.reload.ai_feedback_votes.count } do
      post vote_ai_feedback_membership_application_path(app), params: {
        ai_feedback_vote: { stance: 'disagree', reason: 'Changed mind' }
      }
    end
    vote = app.reload.ai_feedback_votes.sole
    assert_equal 'disagree', vote.stance
    assert_equal 'Changed mind', vote.reason
  end

  test 'vote_ai_feedback rejected when AI not processed' do
    sign_in_as_admin
    app = MembershipApplication.create!(
      email: 'vote-no-ai@example.com',
      status: 'submitted',
      submitted_at: Time.current
    )
    assert_no_difference -> { MembershipApplicationAiFeedbackVote.count } do
      post vote_ai_feedback_membership_application_path(app), params: {
        ai_feedback_vote: { stance: 'agree', reason: '' }
      }
    end
    assert_redirected_to membership_application_path(app)
    assert_equal 'Admin feedback is only available after AI feedback has been processed.', flash[:alert]
  end

  test 'show includes AI feedback section for non-draft applications' do
    app = MembershipApplication.create!(
      email: 'show-ai-section@example.com',
      status: 'submitted',
      submitted_at: Time.current
    )

    get membership_application_path(app)

    assert_response :success
    assert_match(/AI feedback/i, response.body)
  end

  test 'approve blocked for a reviewer who cannot approve' do
    reviewer = sign_in_as_reviewer
    grant_privileges(reviewer, 'applications.view', 'applications.review')
    app = MembershipApplication.create!(
      email: 'approve-gate@example.com',
      status: 'submitted',
      submitted_at: Time.current
    )
    assert_no_changes -> { app.reload.status } do
      post approve_membership_application_path(app), params: { admin_notes: 'n' }
    end
    assert_redirected_to membership_application_path(app)
    assert_match(/do not have permission/i, flash[:alert].to_s)
  end

  test 'approve allowed for a non-admin holding the approve privilege' do
    reviewer = sign_in_as_reviewer
    grant_privileges(reviewer, 'applications.view', 'applications.approve')
    app = MembershipApplication.create!(
      email: 'approve-by-privilege@example.com',
      status: 'submitted',
      submitted_at: Time.current
    )

    post approve_membership_application_path(app), params: { admin_notes: 'Welcome' }

    assert_equal 'approved', app.reload.status
  end

  test 'approve allowed for admins' do
    page1 = ApplicationFormPage.create!(title: 'First page', position: 1)
    q_name = page1.questions.create!(label: 'Name', field_type: 'text', required: false, position: 1)
    q_address = page1.questions.create!(label: 'Mailing Address', field_type: 'text', required: false, position: 2)
    q_phone = page1.questions.create!(label: 'Phone number', field_type: 'text', required: false, position: 3)
    app = MembershipApplication.create!(
      email: 'approve-ok@example.com',
      status: 'submitted',
      submitted_at: Time.current
    )
    app.application_answers.create!(application_form_question: q_name, value: 'Pat Applicant')
    app.application_answers.create!(application_form_question: q_address, value: "123 Privacy Way\nPortland, OR")
    app.application_answers.create!(application_form_question: q_phone, value: '555-123-4567')
    qm = nil
    assert_difference 'User.count', 1 do
      assert_difference 'QueuedMail.count', 1 do
        post approve_membership_application_path(app), params: { admin_notes: 'Welcome' }
        qm = QueuedMail.order(:created_at).last
      end
    end
    assert_redirected_to edit_queued_mail_path(qm)
    app.reload
    assert_equal 'approved', app.status
    assert_equal 'Pat Applicant', app.user.full_name
    assert_equal 'approve-ok@example.com', app.user.email
    assert_equal "123 Privacy Way\nPortland, OR", app.user.mailing_address
    assert_equal '555-123-4567', app.user.phone_number
    assert_equal qm.id, app.outcome_queued_mail_id
    assert_equal 'application_approved', qm.mailer_action
    assert_equal app.user, qm.recipient
  end

  test 'delay_for_review blocked for a reviewer who cannot park applications' do
    reviewer = sign_in_as_reviewer
    grant_privileges(reviewer, 'applications.view', 'applications.review')
    app = MembershipApplication.create!(
      email: 'delay-gate@example.com',
      status: 'submitted',
      submitted_at: Time.current
    )
    assert_no_changes -> { app.reload.status } do
      post delay_for_review_membership_application_path(app), params: { admin_notes: 'Later' }
    end
    assert_redirected_to membership_application_path(app)
    assert_match(/do not have permission/i, flash[:alert].to_s)
  end

  test 'delay_for_review sets under_review' do
    app = MembershipApplication.create!(
      email: 'delay-ok@example.com',
      status: 'submitted',
      submitted_at: Time.current
    )

    assert_difference -> { Journal.where(action: 'application_delayed_for_review').count }, 1 do
      post delay_for_review_membership_application_path(app), params: { admin_notes: 'Deferred' }
    end
    assert_redirected_to membership_application_path(app)
    assert_match(/under review/i, flash[:notice].to_s)
    assert_equal 'under_review', app.reload.status
    assert_equal 'Deferred', app.admin_notes
  end

  test 'delay_for_review redirects when application already under review' do
    app = MembershipApplication.create!(
      email: 'delay-twice@example.com',
      status: 'under_review',
      submitted_at: Time.current,
      reviewed_at: Time.current
    )

    post delay_for_review_membership_application_path(app), params: { admin_notes: 'x' }
    assert_redirected_to membership_application_path(app)
    assert_match(/open applications/i, flash[:alert].to_s)
  end

  test 'mark_needs_review blocked for a reviewer who cannot park applications' do
    reviewer = sign_in_as_reviewer
    grant_privileges(reviewer, 'applications.view', 'applications.review')
    app = MembershipApplication.create!(
      email: 'needs-review-gate@example.com',
      status: 'submitted',
      submitted_at: Time.current
    )
    assert_no_changes -> { app.reload.status } do
      post mark_needs_review_membership_application_path(app), params: { admin_notes: 'Later' }
    end
    assert_redirected_to membership_application_path(app)
    assert_match(/do not have permission/i, flash[:alert].to_s)
  end

  test 'mark_needs_review sets needs_review' do
    app = MembershipApplication.create!(
      email: 'needs-review-ok@example.com',
      status: 'submitted',
      submitted_at: Time.current
    )

    assert_difference -> { Journal.where(action: 'application_marked_needs_review').count }, 1 do
      post mark_needs_review_membership_application_path(app), params: { admin_notes: 'Parked' }
    end
    assert_redirected_to membership_application_path(app)
    assert_match(/needs review/i, flash[:notice].to_s)
    assert_equal 'needs_review', app.reload.status
    assert_equal 'Parked', app.admin_notes
  end

  test 'mark_needs_review redirects when application already parked' do
    app = MembershipApplication.create!(
      email: 'needs-review-twice@example.com',
      status: 'needs_review',
      submitted_at: Time.current,
      reviewed_at: Time.current
    )

    post mark_needs_review_membership_application_path(app), params: { admin_notes: 'x' }
    assert_redirected_to membership_application_path(app)
    assert_match(/open applications/i, flash[:alert].to_s)
  end

  # The Final Decision block offers each verb on its own privilege. Showing the whole block on
  # applications.approve alone hid Reject from members who may reject, and offered buttons that
  # failed on submit to members who may only approve.
  test 'the final decision block offers reject alone to a reviewer who may only reject' do
    reviewer = sign_in_as_reviewer
    grant_privileges(reviewer, 'applications.view', 'applications.reject')
    app = decidable_application('decision-reject-only@example.com')

    get membership_application_path(app)

    assert_response :success
    assert_select 'form[action=?]', reject_membership_application_path(app)
    assert_select 'form[action=?]', approve_membership_application_path(app), count: 0
    assert_select 'form[action=?]', delay_for_review_membership_application_path(app), count: 0
    assert_select 'form[action=?]', mark_needs_review_membership_application_path(app), count: 0
  end

  test 'the final decision block offers approve alone to a reviewer who may only approve' do
    reviewer = sign_in_as_reviewer
    grant_privileges(reviewer, 'applications.view', 'applications.approve')
    app = decidable_application('decision-approve-only@example.com')

    get membership_application_path(app)

    assert_response :success
    assert_select 'form[action=?]', approve_membership_application_path(app)
    assert_select 'form[action=?]', reject_membership_application_path(app), count: 0
    assert_select 'form[action=?]', delay_for_review_membership_application_path(app), count: 0
  end

  test 'the final decision block offers parking to a reviewer who may only park' do
    reviewer = sign_in_as_reviewer
    grant_privileges(reviewer, 'applications.view', 'applications.park_review')
    app = decidable_application('decision-park-only@example.com')

    get membership_application_path(app)

    assert_response :success
    assert_select 'form[action=?]', delay_for_review_membership_application_path(app)
    assert_select 'form[action=?]', mark_needs_review_membership_application_path(app)
    assert_select 'form[action=?]', approve_membership_application_path(app), count: 0
    assert_select 'form[action=?]', reject_membership_application_path(app), count: 0
  end

  test 'the final decision block offers nothing to a reviewer who may only review' do
    reviewer = sign_in_as_reviewer
    grant_privileges(reviewer, 'applications.view', 'applications.review')
    app = decidable_application('decision-none@example.com')

    get membership_application_path(app)

    assert_response :success
    assert_select 'form[action=?]', approve_membership_application_path(app), count: 0
    assert_select 'form[action=?]', reject_membership_application_path(app), count: 0
    assert_match(/do not have permission to approve, reject, or park/i, response.body)
  end

  test 'admins are offered every decision' do
    sign_in_as_admin
    app = decidable_application('decision-admin@example.com')

    get membership_application_path(app)

    assert_response :success
    assert_select 'form[action=?]', approve_membership_application_path(app)
    assert_select 'form[action=?]', reject_membership_application_path(app)
    assert_select 'form[action=?]', mark_needs_review_membership_application_path(app)
  end

  # Approving belongs to the executive director. An admin keeps the button so an acceptance is
  # never blocked, but has to acknowledge that they are stepping outside their role to use it.
  test 'an admin without the approve role is warned before approving' do
    sign_in_as_admin
    app = decidable_application('decision-admin-bypass@example.com')

    get membership_application_path(app)

    assert_response :success
    assert_select 'form[action=?][data-controller=?]',
                  approve_membership_application_path(app), 'admin-override-confirm'
    assert_select 'form[action=?] button[data-turbo-confirm]', approve_membership_application_path(app), count: 0
    # Rejecting is not the director's alone, so it keeps the ordinary confirm.
    assert_select 'form[action=?][data-controller]', reject_membership_application_path(app), count: 0
    assert_select 'form[action=?] button[data-turbo-confirm]', reject_membership_application_path(app)
  end

  test 'an admin who also holds the approve role gets the ordinary confirm' do
    admin = sign_in_as_admin
    grant_privileges(admin, 'applications.approve')
    app = decidable_application('decision-admin-with-role@example.com')

    get membership_application_path(app)

    assert_response :success
    assert_select 'form[action=?][data-controller]', approve_membership_application_path(app), count: 0
    assert_select 'form[action=?] button[data-turbo-confirm]', approve_membership_application_path(app)
  end

  test 'a reviewer with the approve role gets the ordinary confirm' do
    reviewer = sign_in_as_reviewer
    grant_privileges(reviewer, 'applications.view', 'applications.approve')
    app = decidable_application('decision-approver-confirm@example.com')

    get membership_application_path(app)

    assert_response :success
    assert_select 'form[action=?][data-controller]', approve_membership_application_path(app), count: 0
    assert_select 'form[action=?] button[data-turbo-confirm]', approve_membership_application_path(app)
  end

  test 'under review tab includes needs_review applications' do
    app = MembershipApplication.create!(
      email: 'needs-review-index@example.com',
      status: 'needs_review',
      submitted_at: Time.current,
      reviewed_at: Time.current
    )

    get membership_applications_path(status: 'under_review')
    assert_response :success
    assert_select 'a[href=?]', membership_application_path(app)
    assert_includes response.body, 'Needs review'
  end

  test 'reject redirects to edit queued mail' do
    app = MembershipApplication.create!(
      email: 'reject-redirect@example.com',
      status: 'submitted',
      submitted_at: Time.current
    )

    assert_difference 'QueuedMail.count', 1 do
      post reject_membership_application_path(app), params: { admin_notes: 'Not a fit.' }
    end

    qm = QueuedMail.order(:created_at).last
    assert_redirected_to edit_queued_mail_path(qm)
    assert_equal 'rejected', app.reload.status
    assert_equal 'application_rejected', qm.mailer_action
  end

  test 'approve links existing user by email and still queues mail' do
    existing = users(:two)
    app = MembershipApplication.create!(
      email: existing.email,
      status: 'submitted',
      submitted_at: Time.current
    )
    assert_no_difference 'User.count' do
      assert_difference 'QueuedMail.count', 1 do
        post approve_membership_application_path(app), params: {}
      end
    end
    assert_equal existing.id, app.reload.user_id
    assert_redirected_to edit_queued_mail_path(QueuedMail.order(:created_at).last)
  end

  test 'save_tour_feedback creates feedback for current admin' do
    app = MembershipApplication.create!(
      email: 'tour-save@example.com',
      status: 'submitted',
      submitted_at: Time.current
    )
    assert_difference -> { app.reload.tour_feedbacks.count }, 1 do
      post save_tour_feedback_membership_application_path(app), params: {
        tour_feedback: { attitude: 'Positive', impressions: '', engagement: '', fit_feeling: '' }
      }
    end
    assert_redirected_to membership_application_path(app)
    assert_equal 'Positive', app.tour_feedbacks.sole.attitude
  end

  test 'vote_acceptance records tally' do
    app = MembershipApplication.create!(
      email: 'vote-accept@example.com',
      status: 'submitted',
      submitted_at: Time.current
    )
    post vote_acceptance_membership_application_path(app), params: {
      acceptance_vote: { decision: 'accept', comment: 'Strong fit for the shop' }
    }
    assert_redirected_to membership_application_path(app)
    assert_equal({ 'accept' => 1 }, app.reload.acceptance_vote_counts)
    vote = app.acceptance_votes.sole
    assert_equal 'Strong fit for the shop', vote.comment
  end

  test 'vote_acceptance updates existing vote and comment for same admin' do
    sign_in_as_admin
    admin = User.find(session[:user_id])
    app = MembershipApplication.create!(
      email: 'vote-accept-update@example.com',
      status: 'submitted',
      submitted_at: Time.current
    )
    MembershipApplicationAcceptanceVote.create!(
      membership_application: app,
      user: admin,
      decision: 'accept',
      comment: 'First take'
    )
    assert_no_difference -> { app.reload.acceptance_votes.count } do
      post vote_acceptance_membership_application_path(app), params: {
        acceptance_vote: { decision: 'reject', comment: 'Changed after tour' }
      }
    end
    vote = app.reload.acceptance_votes.sole
    assert_equal 'reject', vote.decision
    assert_equal 'Changed after tour', vote.comment
  end

  test 'vote_acceptance rejected when application finalized' do
    app = MembershipApplication.create!(
      email: 'vote-closed@example.com',
      status: 'approved',
      submitted_at: Time.current,
      reviewed_at: Time.current
    )
    assert_no_difference -> { MembershipApplicationAcceptanceVote.count } do
      post vote_acceptance_membership_application_path(app), params: {
        acceptance_vote: { decision: 'reject' }
      }
    end
    assert_redirected_to membership_application_path(app)
    assert_match(/pending/i, flash[:alert].to_s)
  end

  test 'unlink_user clears member on application' do
    app = MembershipApplication.create!(
      email: 'unlink-app-test@example.com',
      status: 'submitted',
      submitted_at: Time.current
    )
    member = users(:member_with_local_account)
    app.update!(user: member)

    post unlink_user_membership_application_path(app)

    assert_redirected_to membership_application_path(app)
    assert_nil app.reload.user_id
  end

  test 'index initiated tab lists verification requests and links matching received applications' do
    verification = ApplicationVerification.create!(
      email: 'initiated-match@example.com',
      confirmed_open_house: true,
      confirmed_code_of_conduct: true
    )
    received = MembershipApplication.create!(
      email: 'initiated-match@example.com',
      status: 'submitted',
      submitted_at: Time.current
    )
    mail_log = MailLogEntry.log_direct_delivery!(
      to: verification.email,
      subject: 'Verify your email',
      mailer_class: 'MemberMailer',
      mailer_action: 'application_email_verification',
      body_html: '<p>Verify</p>'
    )

    get membership_applications_path(status: 'initiated')

    assert_response :success
    assert_select 'a.nav-link.active', text: /Initiated/
    assert_match verification.email, response.body
    assert_select 'a[href=?]', membership_application_path(received)
    assert_select 'a[href=?]', mail_log_entry_path(mail_log)
  end

  test 'extend initiated application by one day' do
    verification = ApplicationVerification.create!(email: 'extend-day@example.com')
    original_expiry = verification.expires_at

    post extend_initiated_membership_applications_path(verification, duration: 'day')

    assert_redirected_to membership_applications_path(status: 'initiated')
    assert_in_delta original_expiry + 1.day, verification.reload.expires_at, 1.second
  end

  test 'extend initiated application by one week' do
    verification = ApplicationVerification.create!(email: 'extend-week@example.com')
    original_expiry = verification.expires_at

    post extend_initiated_membership_applications_path(verification, duration: 'week')

    assert_redirected_to membership_applications_path(status: 'initiated')
    assert_in_delta original_expiry + 1.week, verification.reload.expires_at, 1.second
  end

  test 'resend initiated application confirmation link' do
    verification = ApplicationVerification.create!(email: 'resend@example.com')

    assert_enqueued_emails 1 do
      post resend_initiated_membership_applications_path(verification)
    end

    assert_redirected_to membership_applications_path(status: 'initiated')
    assert_match 'Re-sent the confirmation link', flash[:notice]
  end

  test 'resend initiated application rejects when application already received' do
    verification = ApplicationVerification.create!(email: 'received@example.com')
    MembershipApplication.create!(
      email: verification.email,
      status: 'submitted',
      submitted_at: Time.current
    )

    assert_no_enqueued_emails do
      post resend_initiated_membership_applications_path(verification)
    end

    assert_redirected_to membership_applications_path(status: 'initiated')
    assert_match 'already been received', flash[:alert]
  end

  test 'index initiated tab hides actions when application already received' do
    awaiting_verification = ApplicationVerification.create!(email: 'awaiting@example.com')
    received_verification = ApplicationVerification.create!(email: 'received@example.com')
    MembershipApplication.create!(
      email: received_verification.email,
      status: 'submitted',
      submitted_at: Time.current
    )

    get membership_applications_path(status: 'initiated')

    assert_response :success
    assert_select 'form[action=?]', resend_initiated_membership_applications_path(awaiting_verification)
    assert_select 'form[action=?]', resend_initiated_membership_applications_path(received_verification), count: 0
  end

  test 'index initiated tab shows actions for verified email without received application' do
    verification = ApplicationVerification.create!(email: 'verified-awaiting@example.com')
    verification.verify_email!

    get membership_applications_path(status: 'initiated')

    assert_response :success
    assert_select 'form[action=?]', resend_initiated_membership_applications_path(verification)
  end

  private

  # Submitted, so the Final Decision block offers the parking buttons alongside approve/reject.
  def decidable_application(email)
    MembershipApplication.create!(email: email, status: 'submitted', submitted_at: Time.current)
  end

  def membership_application_with_sensitive_answers
    p1 = ApplicationFormPage.create!(title: 'Contact PII Page', position: 11_101)
    q_mail = p1.questions.create!(label: 'Mailing Address', field_type: 'text', required: false, position: 1)
    q_phone = p1.questions.create!(label: 'Phone number', field_type: 'text', required: false, position: 2)
    p2 = ApplicationFormPage.create!(title: 'Referral PII Page', position: 11_102)
    q_mem_email = p2.questions.create!(label: 'Member Email', field_type: 'text', required: false, position: 1)
    q_mem_phone = p2.questions.create!(label: 'Member Phone', field_type: 'text', required: false, position: 2)
    app = MembershipApplication.create!(
      email: 'pii-test@example.com',
      status: 'submitted',
      submitted_at: Time.current
    )
    app.application_answers.create!(application_form_question: q_mail, value: '123 Secret Street')
    app.application_answers.create!(application_form_question: q_phone, value: '555-000-1111')
    app.application_answers.create!(application_form_question: q_mem_email, value: 'referrer@example.com')
    app.application_answers.create!(application_form_question: q_mem_phone, value: '555-222-3333')
    app
  end

  def sign_in_as_admin
    account = local_accounts(:active_admin)
    post local_login_path, params: {
      session: { email: account.email, password: 'localpassword123' }
    }
    User.find_by!(authentik_id: "local:#{account.id}")
  end

  # A non-admin who reaches applications through privileges alone. Callers grant whichever
  # privileges the case under test needs.
  def sign_in_as_reviewer
    account = local_accounts(:regular_member)
    post local_login_path, params: {
      session: { email: account.email, password: 'memberpassword123' }
    }
    User.find_by!(authentik_id: "local:#{account.id}")
  end
end
