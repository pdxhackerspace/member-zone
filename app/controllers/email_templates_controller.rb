class EmailTemplatesController < AuthenticatedController
  HTML_BLOCK_TAGS = %w[p div h1 h2 h3 h4 h5 h6 li tr].freeze
  HTML_LINK_URL_TAGS = %w[p li].freeze
  HTML_SPACED_TAGS = %w[td th].freeze

  before_action -> { require_privilege!(:'email_templates.view') }, only: %i[index show preview]
  before_action -> { require_privilege!(:'email_templates.edit') }, only: %i[edit update]
  before_action -> { require_privilege!(:'email_templates.test_send') }, only: :test_send
  before_action -> { require_privilege!(:'email_templates.ai_rewrite') }, only: :rewrite_with_ai
  # These stay with administrators. seed overwrites every template from its built-in
  # default and toggle can switch off a transactional message entirely; neither has a
  # catalog key to grant, and mark_reviewed/mark_needs_review record a sign-off that only
  # means something if the person giving it can see every template.
  before_action :require_admin!, only: %i[seed toggle mark_reviewed mark_needs_review]

  before_action :set_email_template,
                only: %i[show edit update preview toggle mark_reviewed mark_needs_review rewrite_with_ai]

  def index
    templates = EmailTemplate.all
    @filter_counts = {
      all: templates.count,
      needs_review: templates.needs_review.count,
      reviewed: templates.reviewed.count,
      enabled: templates.enabled.count,
      disabled: templates.disabled.count,
      send_immediately: templates.send_immediately.count,
      immediate_send_blocked: templates.immediate_send_blocked.count
    }
    @email_templates = templates.ordered
    @filter = params[:filter]

    @email_templates = case @filter
                       when 'needs_review' then @email_templates.needs_review
                       when 'reviewed' then @email_templates.reviewed
                       when 'enabled' then @email_templates.enabled
                       when 'disabled' then @email_templates.disabled
                       when 'send_immediately' then @email_templates.send_immediately
                       when 'immediate_send_blocked' then @email_templates.immediate_send_blocked
                       else @email_templates
                       end
  end

  def show; end

  def edit; end

  def update
    if @email_template.update(email_template_update_params)
      redirect_to email_template_path(@email_template),
                  notice: "Email template '#{@email_template.name}' was successfully updated."
    else
      render :edit, status: :unprocessable_content
    end
  end

  def preview
    apply_preview_attributes if preview_request?
    @rendered = @email_template.preview
    @preview = Emails::BodyComposer.for_preview(
      body_html: @rendered[:body_html],
      body_text: @rendered[:body_text],
      mailer_action: @email_template.key,
      user: current_user,
      email: current_user&.email
    )
    render layout: false
  end

  def toggle
    @email_template.update!(enabled: !@email_template.enabled)
    status = @email_template.enabled? ? 'enabled' : 'disabled'
    redirect_to email_templates_path, notice: "Email template '#{@email_template.name}' has been #{status}."
  end

  def seed
    EmailTemplate.seed_defaults!
    redirect_to email_templates_path, notice: 'Default email templates have been seeded.'
  end

  def mark_reviewed
    @email_template.update!(needs_review: false)
    redirect_to email_template_path(@email_template), notice: "Template '#{@email_template.name}' marked as reviewed."
  end

  def mark_needs_review
    @email_template.update!(needs_review: true)
    redirect_to email_template_path(@email_template), notice: "Template '#{@email_template.name}' flagged for review."
  end

  def test_send
    @email_template = EmailTemplate.find(params[:id])

    # Find a user to send test to (prefer current user)
    test_user = current_user

    if test_user&.email.present?
      # Render the template
      variables = build_variables_for_user(test_user)
      rendered = @email_template.render(variables)

      # Send via ActionMailer
      TestMailer.send_template(
        to: test_user.email,
        subject: rendered[:subject],
        body_html: rendered[:body_html],
        body_text: rendered[:body_text]
      ).deliver_later

      redirect_to email_templates_path, notice: "Test email sent to #{test_user.email}."
    else
      redirect_to email_templates_path, alert: 'Could not send test email - no email address available.'
    end
  end

  def rewrite_with_ai
    attrs = rewrite_params
    result = EmailTemplates::RewriteWithAi.call(
      subject: attrs[:subject],
      body_html: attrs[:body_html],
      body_text: attrs[:body_text]
    )

    if result.success?
      render json: {
        subject: result.subject,
        body_html: result.body_html,
        body_text: result.body_text,
        message: result.message
      }
    else
      render json: { error: result.message }, status: :unprocessable_content
    end
  end

  private

  def set_email_template
    @email_template = EmailTemplate.find(params[:id])
  end

  def email_template_params
    params.expect(email_template: %i[
                    name description subject body_html body_text enabled send_immediately block_send_immediately
                  ])
  end

  def email_template_update_params
    attrs = email_template_params.to_h
    attrs['body_text'] = html_to_plain_text(attrs['body_html']) if sync_body_text?
    attrs
  end

  def sync_body_text?
    params[:sync_body_text].present?
  end

  def html_to_plain_text(html)
    fragment = Nokogiri::HTML.fragment(html.to_s)
    node_to_plain_text(fragment)
      .gsub("\u00a0", ' ')
      .gsub(/[ \t]+\n/, "\n")
      .gsub(/\n[ \t]+/, "\n")
      .gsub(/\n{3,}/, "\n\n")
      .strip
  end

  def node_to_plain_text(node)
    return node.text if node.text?
    return "\n" if node.element? && node.name == 'br'

    text = node.children.map { |child| node_to_plain_text(child) }.join
    if append_link_urls?(node)
      urls = node.css('a[href]').filter_map { |link| link['href'].presence }
      text = append_link_urls(text, urls)
    end
    text += "\n" if node.element? && HTML_BLOCK_TAGS.include?(node.name)
    text += ' ' if node.element? && HTML_SPACED_TAGS.include?(node.name)
    text
  end

  def append_link_urls?(node)
    node.element? && HTML_LINK_URL_TAGS.include?(node.name) && node.css('a[href]').any?
  end

  def append_link_urls(text, urls)
    return text if urls.blank?

    [text.rstrip, '', *urls, ''].join("\n")
  end

  def rewrite_params
    params.expect(rewrite: %i[subject body_html body_text])
  end

  def preview_request?
    request.post? && params[:email_template].present?
  end

  def apply_preview_attributes
    attrs = email_template_params.to_h.slice('subject', 'body_html', 'body_text')
    attrs['body_text'] = html_to_plain_text(attrs['body_html']) if sync_body_text?
    @email_template.assign_attributes(attrs)
  end

  def build_variables_for_user(user, extra = {})
    {
      member_name: user.display_name,
      member_email: user.email || 'Not provided',
      member_username: user.username || 'Not set',
      organization_name: ENV.fetch('ORGANIZATION_NAME', 'Member Zone'),
      date: Date.current.strftime('%B %d, %Y'),
      app_url: ENV.fetch('APP_BASE_URL', 'http://localhost:3000')
    }.merge(extra)
  end
end
