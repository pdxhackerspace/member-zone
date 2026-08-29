require 'test_helper'

class EmailTemplatesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true
    sign_in_as_admin
    @template = EmailTemplate.create!(
      key: 'rewrite_test_template',
      name: 'Rewrite Test Template',
      subject: 'Initial Subject',
      body_html: '<p>Initial HTML</p>',
      body_text: 'Initial text',
      enabled: true
    )
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  test 'preview shows saved template on get' do
    get preview_email_template_path(@template)

    assert_response :success
    assert_includes response.body, 'Initial Subject'
    assert_includes response.body, 'Initial HTML'
    assert_includes response.body, 'Initial text'
  end

  test 'preview includes the outgoing email banner and opt-out footer added on send' do
    ReminderSetting.seed_defaults!
    ReminderSetting.find_by!(key: 'payment_overdue').update!(allow_opt_out: true)
    TextFragment.ensure_exists!(key: 'outgoing_email_banner', title: 'Outgoing email banner', content: '')
    TextFragment.find_by!(key: 'outgoing_email_banner').update!(content: '<p>Office closed Monday.</p>')
    template = EmailTemplate.create!(
      key: 'payment_past_due',
      name: 'Payment past due',
      subject: 'Dues past due',
      body_html: '<p>Your dues are past due.</p>',
      body_text: 'Your dues are past due.',
      enabled: true
    )

    get preview_email_template_path(template)

    assert_response :success
    assert_includes response.body, 'Office closed Monday.'
    assert_includes response.body, 'Manage overdue payment reminders'
  end

  test 'preview shows unsaved edits on post' do
    post preview_email_template_path(@template), params: {
      email_template: {
        subject: 'Draft Subject',
        body_html: '<p>Draft HTML</p>',
        body_text: 'Draft text'
      }
    }

    assert_response :success
    assert_includes response.body, 'Draft Subject'
    assert_includes response.body, 'Draft HTML'
    assert_includes response.body, 'Draft text'
    assert_not_includes response.body, 'Initial Subject'
    @template.reload
    assert_equal 'Initial Subject', @template.subject
  end

  test 'preview post syncs plain text from html when checkbox is checked' do
    post preview_email_template_path(@template), params: {
      sync_body_text: '1',
      email_template: {
        subject: 'Draft Subject',
        body_html: '<h1>Welcome</h1><p>Hello {{member_name}}</p>',
        body_text: 'Stale plain text'
      }
    }

    assert_response :success
    assert_includes response.body, 'Welcome'
    assert_includes response.body, 'Hello John Doe'
    assert_includes response.body, "Welcome\nHello John Doe"
  end

  test 'edit preview button posts draft content' do
    get edit_email_template_path(@template)

    assert_response :success
    assert_select 'button[type=?]', 'button', text: 'Preview' do |buttons|
      button = buttons.first
      assert_equal 'email_template_form', button['data-email-template-rewrite-form-id-value']
      assert_equal preview_email_template_path(@template), button['data-email-template-rewrite-preview-url-value']
      assert_equal 'click->email-template-rewrite#preview', button['data-action']
    end
    assert_select 'form#email_template_form[data-controller=?]', 'email-template-rewrite'
  end

  test 'training_requested edit lists slack handle in available variables' do
    template = EmailTemplate.find_or_create_by!(key: 'training_requested') do |record|
      record.assign_attributes(EmailTemplate::DEFAULT_TEMPLATES['training_requested'])
    end

    get edit_email_template_path(template)

    assert_response :success
    assert_match '{{requester_slack}}', response.body
    assert_match 'Slack handle of the member requesting training', response.body
  end

  test 'rewrite_with_ai rewrites subject and body' do
    ai_ollama_profiles(:default).update!(base_url: 'http://ollama.test:11434', model: 'llama3.2')
    ai_ollama_profiles(:email_rewriting).update!(enabled: true, base_url: '', model: '', prompt: 'Rewrite template.')

    response_json = {
      subject: 'Improved Subject',
      body_html: '<p>Improved HTML</p>',
      body_text: 'Improved text'
    }
    stub_result = Ollama::ChatCompletion::Result.new(true, JSON.generate(response_json), nil)

    original_call = Ollama::ChatCompletion.method(:call)
    Ollama::ChatCompletion.define_singleton_method(:call) { |**_kwargs| stub_result }
    begin
      post rewrite_with_ai_email_template_path(@template), params: {
        rewrite: {
          subject: @template.subject,
          body_html: @template.body_html,
          body_text: @template.body_text
        }
      }, as: :json
    ensure
      Ollama::ChatCompletion.define_singleton_method(:call, original_call)
    end

    assert_response :success
    parsed = response.parsed_body
    assert_equal 'Improved Subject', parsed['subject']
    assert_equal '<p>Improved HTML</p>', parsed['body_html']
    assert_equal 'Improved text', parsed['body_text']
  end

  test 'edit shows text sync checkbox checked by default' do
    get edit_email_template_path(@template)

    assert_response :success
    assert_select 'input#email_template_sync_body_text[name=?][checked]', 'sync_body_text'
    assert_select 'label[for=?]', 'email_template_sync_body_text', text: 'Keep in sync with HTML'
  end

  test 'edit shows immediate send controls' do
    get edit_email_template_path(@template)

    assert_response :success
    assert_select 'input[name=?][data-email-template-rewrite-target=?]',
                  'email_template[send_immediately]', 'sendImmediately'
    assert_select 'input[name=?][data-email-template-rewrite-target=?][data-action=?]',
                  'email_template[block_send_immediately]',
                  'blockSendImmediately',
                  'change->email-template-rewrite#syncImmediateSendControls'
  end

  test 'index shows immediate send flags' do
    @template.update!(send_immediately: true)

    get email_templates_path

    assert_response :success
    assert_select 'span', text: 'Send immediately'
  end

  test 'index shows filter chips with counts' do
    get email_templates_path

    assert_response :success
    assert_select '.filter-chip', 7
    assert_includes response.body, 'All <span class="count">1</span>'
    assert_includes response.body, 'Needs review <span class="count">1</span>'
    assert_includes response.body, 'Reviewed <span class="count">0</span>'
    assert_includes response.body, 'Enabled <span class="count">1</span>'
    assert_includes response.body, 'Disabled <span class="count">0</span>'
    assert_includes response.body, 'Send immediately <span class="count">0</span>'
    assert_includes response.body, 'Immediate send blocked <span class="count">0</span>'
  end

  test 'index disables zero count filter chips' do
    get email_templates_path

    assert_response :success
    assert_select 'span.filter-chip.muted[aria-disabled=?]', 'true', text: /Send immediately\s+0/
    assert_select "a[href='#{email_templates_path(filter: 'send_immediately')}']", count: 0
  end

  test 'index filters by immediate send states' do
    @template.update!(send_immediately: true)
    blocked_template = EmailTemplate.create!(
      key: 'blocked_immediate_template',
      name: 'Blocked Immediate Template',
      subject: 'Blocked Subject',
      body_html: '<p>Blocked HTML</p>',
      body_text: 'Blocked text',
      enabled: true,
      block_send_immediately: true
    )

    get email_templates_path(filter: 'send_immediately')

    assert_response :success
    assert_select 'tbody tr', 1
    assert_select 'td', text: /#{@template.name}/
    assert_select 'td', text: /#{blocked_template.name}/, count: 0

    get email_templates_path(filter: 'immediate_send_blocked')

    assert_response :success
    assert_select 'tbody tr', 1
    assert_select 'td', text: /#{blocked_template.name}/
    assert_select 'td', text: /#{@template.name}/, count: 0
  end

  test 'update cannot enable send immediately while blocked' do
    patch email_template_path(@template), params: {
      email_template: {
        name: @template.name,
        description: @template.description,
        subject: 'Updated Subject',
        body_html: '<p>Replacement HTML</p>',
        body_text: 'Replacement text',
        enabled: '1',
        send_immediately: '1',
        block_send_immediately: '1'
      }
    }

    assert_redirected_to email_template_path(@template)
    @template.reload
    assert @template.block_send_immediately?
    assert_not @template.send_immediately?
  end

  test 'update redirects back to template view' do
    patch email_template_path(@template), params: {
      email_template: {
        name: @template.name,
        description: @template.description,
        subject: 'Updated Subject',
        body_html: '<p>Replacement HTML</p>',
        body_text: 'Replacement text',
        enabled: '1'
      }
    }

    assert_redirected_to email_template_path(@template)
  end

  test 'mark reviewed redirects back to template view' do
    @template.update!(needs_review: true)

    post mark_reviewed_email_template_path(@template)

    assert_redirected_to email_template_path(@template)
    assert_not @template.reload.needs_review?
  end

  test 'show wraps html body in high contrast preview container' do
    get email_template_path(@template)

    assert_response :success
    assert_select '.email-template-html-body'
  end

  test 'update syncs plain text from html when checkbox is checked' do
    patch email_template_path(@template), params: {
      sync_body_text: '1',
      email_template: {
        name: @template.name,
        description: @template.description,
        subject: 'Updated Subject',
        body_html: '<h1>Welcome</h1><p>Hello <strong>{{member_name}}</strong><br>Line two</p>',
        body_text: 'Stale plain text',
        enabled: '1'
      }
    }

    assert_redirected_to email_template_path(@template)
    @template.reload
    assert_equal '<h1>Welcome</h1><p>Hello <strong>{{member_name}}</strong><br>Line two</p>', @template.body_html
    assert_equal "Welcome\nHello {{member_name}}\nLine two", @template.body_text
  end

  test 'update sync lists link urls under their containing paragraph' do
    html = <<~HTML.squish
      <p>Visit <a href="https://example.com/start">the getting started guide</a>
      and <a href="{{application_url}}">your application</a>.</p>
      <p>Thanks for reading.</p>
    HTML

    patch email_template_path(@template), params: {
      sync_body_text: '1',
      email_template: {
        name: @template.name,
        description: @template.description,
        subject: 'Updated Subject',
        body_html: html,
        body_text: 'Stale plain text',
        enabled: '1'
      }
    }

    assert_redirected_to email_template_path(@template)
    @template.reload
    assert_equal <<~TEXT.strip, @template.body_text
      Visit the getting started guide and your application.

      https://example.com/start
      {{application_url}}

      Thanks for reading.
    TEXT
  end

  test 'update leaves plain text unchanged when checkbox is unchecked' do
    patch email_template_path(@template), params: {
      email_template: {
        name: @template.name,
        description: @template.description,
        subject: 'Updated Subject',
        body_html: '<p>Replacement HTML</p>',
        body_text: 'Custom plain text',
        enabled: '1'
      }
    }

    assert_redirected_to email_template_path(@template)
    @template.reload
    assert_equal '<p>Replacement HTML</p>', @template.body_html
    assert_equal 'Custom plain text', @template.body_text
  end

  private

  def sign_in_as_admin
    account = local_accounts(:active_admin)
    post local_login_path, params: {
      session: {
        email: account.email,
        password: 'localpassword123'
      }
    }
  end
end
