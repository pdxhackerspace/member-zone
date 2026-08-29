require 'test_helper'

class QueuedMailsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true
    sign_in_as_local_admin
    @pending = queued_mails(:pending_mail)
    @approved = queued_mails(:approved_mail)
    @original_smtp = Rails.configuration.action_mailer.smtp_settings&.dup
    Rails.configuration.action_mailer.smtp_settings = { address: 'smtp.test.example.com', user_name: 'test',
                                                        password: 'test' }
  end

  teardown do
    Rails.configuration.action_mailer.smtp_settings = @original_smtp
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  # ─── Index ────────────────────────────────────────────────────────

  test 'shows index with pending filter by default' do
    get queued_mails_path
    assert_response :success
    assert_select 'h1', /Mail Queue/
  end

  test 'shows index with approved filter' do
    get queued_mails_path(filter: 'approved')
    assert_response :success
  end

  test 'shows index with rejected filter' do
    get queued_mails_path(filter: 'rejected')
    assert_response :success
  end

  test 'shows index with all filter' do
    get queued_mails_path(filter: 'all')
    assert_response :success
  end

  # ─── Show ─────────────────────────────────────────────────────────

  test 'shows queued mail' do
    get queued_mail_path(@pending)
    assert_response :success
    assert_match @pending.subject, response.body
    assert_match @pending.to, response.body
  end

  test 'show preview includes the banner and footer that delivery adds' do
    TextFragment.ensure_exists!(key: 'outgoing_email_banner', title: 'Outgoing email banner', content: '')
    TextFragment.find_by!(key: 'outgoing_email_banner').update!(content: '<p>Office closed Monday.</p>')

    get queued_mail_path(@pending)

    assert_response :success
    assert_includes response.body, 'Office closed Monday.'
    assert_includes response.body, 'This is a required notice and cannot be turned off.'
  end

  test 'show preview does not double the banner on pre-rendered bodies' do
    TextFragment.ensure_exists!(key: 'outgoing_email_banner', title: 'Outgoing email banner', content: '')
    TextFragment.find_by!(key: 'outgoing_email_banner').update!(content: '<p>Office closed Monday.</p>')
    EmailTemplate.where(key: 'payment_past_due').delete_all
    queued = QueuedMail.enqueue(:payment_past_due, users(:member_with_local_account), reason: 'Test')

    get queued_mail_path(queued)

    assert_response :success
    assert_predicate queued, :pre_rendered_mail_body?
    srcdoc = css_select('iframe#mail_preview').first['srcdoc']
    assert_equal 1, srcdoc.scan('Office closed Monday.').size
  end

  # ─── Edit ─────────────────────────────────────────────────────────

  test 'shows edit form for pending mail' do
    get edit_queued_mail_path(@pending)
    assert_response :success
    assert_select 'form'
    assert_select 'input#queued_mail_sync_body_text[name=?][checked]', 'sync_body_text'
    assert_select 'label[for=?]', 'queued_mail_sync_body_text', text: 'Keep in sync with HTML'
  end

  test 'redirects edit for non-pending mail' do
    get edit_queued_mail_path(@approved)
    assert_redirected_to queued_mail_path(@approved)
  end

  # ─── Update ───────────────────────────────────────────────────────

  test 'updates pending mail' do
    patch queued_mail_path(@pending), params: {
      queued_mail: {
        subject: 'Updated Subject',
        body_html: '<p>Updated body</p>'
      }
    }
    assert_redirected_to queued_mail_path(@pending)
    @pending.reload
    assert_equal 'Updated Subject', @pending.subject
  end

  test 'update syncs plain text from html when checkbox is checked' do
    patch queued_mail_path(@pending), params: {
      sync_body_text: '1',
      queued_mail: {
        to: @pending.to,
        subject: 'Updated Subject',
        body_html: '<h1>Welcome</h1><p>Hello <strong>member</strong><br>Line two</p>',
        body_text: 'Stale plain text'
      }
    }

    assert_redirected_to queued_mail_path(@pending)
    @pending.reload
    assert_equal '<h1>Welcome</h1><p>Hello <strong>member</strong><br>Line two</p>', @pending.body_html
    assert_equal "Welcome\nHello member\nLine two", @pending.body_text
  end

  test 'update sync lists link urls under their containing paragraph' do
    html = <<~HTML.squish
      <p>Review <a href="https://example.com/message">this message</a>
      and <a href="{{application_url}}">the application</a>.</p>
      <p>Thanks for helping.</p>
    HTML

    patch queued_mail_path(@pending), params: {
      sync_body_text: '1',
      queued_mail: {
        to: @pending.to,
        subject: 'Updated Subject',
        body_html: html,
        body_text: 'Stale plain text'
      }
    }

    assert_redirected_to queued_mail_path(@pending)
    @pending.reload
    assert_equal <<~TEXT.strip, @pending.body_text
      Review this message and the application.

      https://example.com/message
      {{application_url}}

      Thanks for helping.
    TEXT
  end

  test 'update leaves plain text unchanged when checkbox is unchecked' do
    patch queued_mail_path(@pending), params: {
      queued_mail: {
        to: @pending.to,
        subject: 'Updated Subject',
        body_html: '<p>Replacement HTML</p>',
        body_text: 'Custom plain text'
      }
    }

    assert_redirected_to queued_mail_path(@pending)
    @pending.reload
    assert_equal '<p>Replacement HTML</p>', @pending.body_html
    assert_equal 'Custom plain text', @pending.body_text
  end

  test 'rejects update for non-pending mail' do
    patch queued_mail_path(@approved), params: {
      queued_mail: { subject: 'Should not update' }
    }
    assert_redirected_to queued_mail_path(@approved)
    @approved.reload
    assert_not_equal 'Should not update', @approved.subject
  end

  # ─── Approve ──────────────────────────────────────────────────────

  test 'approves pending mail and sends it' do
    assert_enqueued_jobs 1, only: QueuedMailDeliveryJob do
      post approve_queued_mail_path(@pending)
    end
    assert_redirected_to queued_mails_path

    @pending.reload
    assert @pending.approved?
    # sent_at is set when the delivery job runs, not when enqueued
  end

  test 'cannot approve already reviewed mail' do
    post approve_queued_mail_path(@approved)
    assert_redirected_to queued_mail_path(@approved)
  end

  test 'approve shows opt-out alert when recipient unsubscribed after queueing' do
    ReminderSetting.seed_defaults!
    user = users(:member_with_local_account)
    mail = QueuedMail.create!(
      to: user.email,
      subject: 'Payment reminder',
      body_html: '<p>Hi</p>',
      body_text: 'Hi',
      reason: 'Test',
      mailer_action: 'payment_past_due',
      recipient: user,
      status: 'pending'
    )
    NotificationOptOut.opt_out!(user, category: 'payment_overdue', channel: 'email')

    post approve_queued_mail_path(mail)

    assert_redirected_to queued_mail_path(mail)
    assert_match 'opted out of overdue payment reminders', flash[:alert]
    assert_no_match 'banned', flash[:alert]
  end

  # ─── Reject ──────────────────────────────────────────────────────

  test 'rejects pending mail' do
    post reject_queued_mail_path(@pending)
    assert_redirected_to queued_mails_path

    @pending.reload
    assert @pending.rejected?
    assert_nil @pending.sent_at
  end

  test 'cannot reject already reviewed mail' do
    post reject_queued_mail_path(@approved)
    assert_redirected_to queued_mail_path(@approved)
  end

  # ─── Regenerate ──────────────────────────────────────────────────

  test 'regenerates pending mail from view template' do
    post regenerate_queued_mail_path(@pending)
    assert_redirected_to queued_mail_path(@pending)
  end

  test 'cannot regenerate non-pending mail' do
    post regenerate_queued_mail_path(@approved)
    assert_redirected_to queued_mail_path(@approved)
  end

  test 'rewrite_with_ai rewrites body in place for pending mail' do
    ai_ollama_profiles(:default).update!(base_url: 'http://ollama.test:11434', model: 'llama3.2')
    ai_ollama_profiles(:email_rewriting).update!(enabled: true, base_url: '', model: '', prompt: 'Rewrite this email.')

    response_json = {
      body_html: '<p>Rewritten HTML</p>',
      body_text: 'Rewritten text'
    }
    stub_result = Ollama::ChatCompletion::Result.new(true, JSON.generate(response_json), nil)

    original_call = Ollama::ChatCompletion.method(:call)
    Ollama::ChatCompletion.define_singleton_method(:call) { |**_kwargs| stub_result }
    begin
      post rewrite_with_ai_queued_mail_path(@pending), params: {
        rewrite: {
          subject: @pending.subject,
          body_html: @pending.body_html,
          body_text: @pending.body_text
        }
      }, as: :json
    ensure
      Ollama::ChatCompletion.define_singleton_method(:call, original_call)
    end

    assert_response :success
    parsed = response.parsed_body
    assert_equal '<p>Rewritten HTML</p>', parsed['body_html']
    assert_equal 'Rewritten text', parsed['body_text']
  end

  test 'rewrite_with_ai rejects non-pending mail' do
    post rewrite_with_ai_queued_mail_path(@approved), params: {
      rewrite: {
        subject: @approved.subject,
        body_html: @approved.body_html,
        body_text: @approved.body_text
      }
    }, as: :json

    assert_response :unprocessable_content
    parsed = response.parsed_body
    assert_match(/Only pending messages/, parsed['error'])
  end

  # ─── Access ───────────────────────────────────────────────────────

  test 'signing out closes the queue' do
    delete logout_path
    get queued_mails_path
    assert_redirected_to login_path
  end

  # This used to be called "non-admin cannot access queue" while actually signing out — so
  # it never covered a signed-in member without the privilege, which is the case that
  # matters now that the queue is privilege-gated.
  test 'a signed-in member without queued_mail.view cannot access the queue' do
    delete logout_path
    sign_in_as_plain_member

    get queued_mails_path

    assert_response :redirect
    assert_no_match(/login/, response.location)
  end

  private

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
