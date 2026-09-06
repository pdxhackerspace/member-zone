require 'test_helper'

# Unreplaced tokens are stripped rather than left visible, so a variable with no preview sample
# does not announce itself — the surrounding sentence just quietly loses a word. These tests walk
# the default templates so a new variable cannot be added without a sample and a description.
class EmailTemplatePreviewVariablesTest < ActiveSupport::TestCase
  DEFAULT_TEMPLATE_TOKENS = EmailTemplate::DEFAULT_TEMPLATES.flat_map do |key, attrs|
    body = attrs.values_at(:subject, :body_html, :body_text).compact.join("\n")
    body.scan(/\{\{([^}]+)\}\}/).flatten.uniq.map { |token| [key, token] }
  end.freeze

  test 'every variable used by a default template has a preview sample' do
    samples = EmailTemplate::PreviewVariables.all
    missing = DEFAULT_TEMPLATE_TOKENS.reject { |_key, token| samples.key?(token.to_sym) }

    assert_empty missing.map { |key, token| "#{key}: {{#{token}}}" },
                 'these template variables would render as an empty string in the admin preview'
  end

  test 'every variable used by a default template is described for the editor' do
    missing = DEFAULT_TEMPLATE_TOKENS.reject do |_key, token|
      EmailTemplate::AVAILABLE_VARIABLES.key?("{{#{token}}}")
    end

    assert_empty missing.map { |key, token| "#{key}: {{#{token}}}" },
                 'these template variables are undocumented in the template editor'
  end

  test 'every described variable has a preview sample' do
    samples = EmailTemplate::PreviewVariables.all
    missing = EmailTemplate::AVAILABLE_VARIABLES.keys.reject do |name|
      samples.key?(name.delete('{}').to_sym)
    end

    assert_empty missing, 'these documented variables have no preview sample'
  end

  test 'no default template previews with an empty substitution' do
    EmailTemplate::DEFAULT_TEMPLATES.each do |key, attrs|
      template = EmailTemplate.new(key: key, name: attrs[:name], subject: attrs[:subject],
                                   body_html: attrs[:body_html], body_text: attrs[:body_text])
      rendered = template.preview

      assert_no_match(/\{\{/, rendered.values.join, "#{key} left an unsubstituted token")
      assert_no_collapsed_sentence(rendered[:body_text], key)
    end
  end

  test 'the lapsed access preview shows the visit wording the reminder is built around' do
    template = default_template('lapsed_access_reminder')
    rendered = template.preview

    assert_includes rendered[:body_text], 'facilities 3 times between April 24 and April 27'
    assert_includes rendered[:body_text], 'lapsed on March 15, 2026'
    assert_includes rendered[:body_text], 'reactivate without reapplying'
    assert_includes rendered[:body_html], 'href="mailto:info@example.com"'
    assert_includes rendered[:body_html], '/users/johndoe'
  end

  test 'the slack signup preview keeps the paragraph break the template relies on' do
    rendered = default_template('slack_signup_reminder').preview

    assert_includes rendered[:body_text],
                    "Associate your Slack account: #{sample_slack_url}\n\nIf you do not have a Slack account yet"
    assert_includes rendered[:body_html], %(<a href="#{sample_slack_url}">Associate your Slack account</a>)
  end

  # The template puts {{slack_link_text}} immediately before the next sentence, so the sample owns
  # the blank line between them. Deriving it from the mailer is what keeps the two in step.
  test 'the slack fragments are the ones the mailer sends' do
    samples = EmailTemplate::PreviewVariables.all
    sent = MemberMailer.slack_link_fragments(sample_slack_url)

    assert_equal sent[:slack_link_text], samples[:slack_link_text]
    assert_equal sent[:slack_link_html], samples[:slack_link_html]
  end

  # Whitespace is part of the value for variables the templates place inline. A sample that trims
  # it renders as running text with no error anywhere, so it is worth pinning explicitly.
  test 'samples keep the padding their templates depend on' do
    samples = EmailTemplate::PreviewVariables.all

    assert samples[:slack_link_text].end_with?("\n\n"),
           'slack_link_text separates itself from the sentence that follows it'
    assert samples[:days_overdue].start_with?(' '),
           'days_overdue is appended to a sentence and carries its own leading space'
  end

  test 'the blocked recipient preview names the member and the blocked message' do
    rendered = default_template('blocked_recipient_delivery_attempt').preview

    assert_includes rendered[:body_text], 'Jane Doe'
    assert_includes rendered[:body_text], 'jane.doe@example.com'
    assert_includes rendered[:body_text], 'Your dues are past due'
    assert_includes rendered[:body_text], 'banned'
  end

  private

  def sample_slack_url
    "#{ENV.fetch('APP_BASE_URL', 'http://localhost:3000')}/slack/link"
  end

  def default_template(key)
    attrs = EmailTemplate::DEFAULT_TEMPLATES.fetch(key)
    EmailTemplate.new(key: key, name: attrs[:name], subject: attrs[:subject],
                      body_html: attrs[:body_html], body_text: attrs[:body_text])
  end

  # Catches the shape a missing variable leaves behind: a dangling space before punctuation, as in
  # "you used the space , but your membership lapsed on ."
  def assert_no_collapsed_sentence(text, key)
    offenders = text.to_s.lines.grep(/\s[,.]|\s[,.]$/).map(&:strip)

    assert_empty offenders, "#{key} previews with a gap where a variable should be: #{offenders.inspect}"
  end
end
