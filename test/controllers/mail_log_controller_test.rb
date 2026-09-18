require 'test_helper'

class MailLogControllerTest < ActionDispatch::IntegrationTest
  setup do
    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true
    sign_in_as_local_admin
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  test 'show displays direct mail message snapshot' do
    entry = MailLogEntry.log_direct_delivery!(
      to: 'applicant@example.com',
      subject: 'Verify your email',
      mailer_class: 'MemberMailer',
      mailer_action: 'application_email_verification',
      body_html: '<p>Use this verification link.</p>',
      body_text: 'Use this verification link.'
    )

    get mail_log_entry_path(entry)

    assert_response :success
    assert_match 'Verify your email', response.body
    assert_match 'Use this verification link.', response.body
  end

  test 'index links log rows to their detail pages' do
    entry = MailLogEntry.log_queued_delivery!(queued_mails(:approved_mail))

    get mail_log_path

    assert_response :success
    assert_select 'a[href=?]', mail_log_entry_path(entry)
  end

  test 'index filters by the state of the message' do
    sent = MailLogEntry.log_queued_delivery!(queued_mails(:approved_mail))
    failed = MailLogEntry.log!(queued_mails(:pending_mail), 'send_failed', details: 'Net::SMTPServerBusy: try later')

    get mail_log_path(state: 'failed')

    assert_response :success
    assert_select 'a[href=?]', mail_log_entry_path(failed)
    assert_select 'a[href=?]', mail_log_entry_path(sent), false
  end

  test 'index filters by recipient and subject' do
    match = MailLogEntry.log_direct_delivery!(
      to: 'needle@example.com', subject: 'Verify your email',
      mailer_class: 'MemberMailer', mailer_action: 'application_email_verification'
    )
    other = MailLogEntry.log_direct_delivery!(
      to: 'haystack@example.com', subject: 'Welcome aboard',
      mailer_class: 'MemberMailer', mailer_action: 'membership_approved'
    )

    get mail_log_path(q: 'needle@')

    assert_response :success
    assert_select 'a[href=?]', mail_log_entry_path(match)
    assert_select 'a[href=?]', mail_log_entry_path(other), false
  end

  test 'index rejects an unknown state rather than showing nothing' do
    entry = MailLogEntry.log_queued_delivery!(queued_mails(:approved_mail))

    get mail_log_path(state: 'nonsense')

    assert_response :success
    assert_select 'a[href=?]', mail_log_entry_path(entry)
  end

  test 'every filter chip carries the size of its bucket' do
    MailLogEntry.log_queued_delivery!(queued_mails(:approved_mail))

    get mail_log_path

    assert_response :success
    MailLogHelper::STATE_CHIPS.each do |chip|
      assert_select '.filter-chip', text: /#{chip[:label]}\s+\d+/, count: 1
    end
    assert_select '.filter-chip.active', text: /All\s+\d+/, count: 1
  end

  test 'the selected chip is the one being filtered on' do
    MailLogEntry.log!(queued_mails(:pending_mail), 'send_failed', details: 'Net::SMTPServerBusy: try later')

    get mail_log_path(state: 'failed')

    assert_response :success
    assert_select '.filter-chip.active', text: /Failed\s+\d+/, count: 1
  end

  test 'a chip for an empty bucket is not a link' do
    MailLogEntry.where(event: 'rejected').delete_all

    get mail_log_path

    assert_response :success
    assert_select 'span.filter-chip.muted', text: /Rejected\s+0/
    assert_select 'a.filter-chip[href=?]', mail_log_path(state: 'rejected'), false
  end

  test 'index shows 50 entries a page' do
    create_log_entries(55)

    get mail_log_path

    assert_response :success
    assert_select 'tbody tr', MailLogController::PER_PAGE
    assert_select 'ul.pagination a[href*=?]', 'page=2'
  end

  test 'the rest of the log is on the following page' do
    create_log_entries(55)
    total = MailLogEntry.count

    get mail_log_path(page: 2)

    assert_response :success
    assert_select 'tbody tr', total - MailLogController::PER_PAGE
  end

  test 'paging through a filtered log keeps the filter and the search' do
    create_log_entries(55, to: 'needle@example.com')

    get mail_log_path(state: 'sent', q: 'needle@')

    assert_response :success
    assert_select 'ul.pagination a[href*=?]', 'state=sent'
    assert_select 'ul.pagination a[href*=?]', 'q=needle'
  end

  test 'a log that fits on one page shows no pagination' do
    MailLogEntry.log_queued_delivery!(queued_mails(:approved_mail))

    get mail_log_path

    assert_response :success
    assert_select 'ul.pagination', false
  end

  test 'index points at failed messages still waiting in the queue' do
    queued_mails(:approved_mail).update!(sent_at: nil, last_error: 'Net::SMTPServerBusy: try later',
                                         last_error_at: Time.current)

    get mail_log_path

    assert_response :success
    assert_select 'a[href=?]', queued_mails_path(filter: 'failed')
  end

  private

  def create_log_entries(count, to: 'bulk@example.com')
    count.times do |i|
      MailLogEntry.log_direct_delivery!(
        to: to, subject: "Bulk message #{i}",
        mailer_class: 'MemberMailer', mailer_action: 'membership_approved'
      )
    end
  end

  def sign_in_as_local_admin
    account = local_accounts(:active_admin)
    post local_login_path, params: {
      session: {
        email: account.email,
        password: 'localpassword123'
      }
    }
  end
end
