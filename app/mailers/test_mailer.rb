# Mailer for sending test emails from email templates
class TestMailer < ApplicationMailer
  def send_template(to:, subject:, body_html:, body_text:)
    @body_html = body_html
    @body_text = body_text

    mail(
      to: to,
      subject: subject
    ) do |format|
      format.html { render html: @body_html.html_safe, layout: 'mailer' }
      plain = plain_text_email_body(@body_text)
      format.text { render plain: plain } if plain.present?
    end
  end
end
