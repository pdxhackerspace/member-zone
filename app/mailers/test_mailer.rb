# Mailer for sending test emails from email templates
class TestMailer < ApplicationMailer
  # A test send is a diagnostic an admin is watching for, not a message anyone is waiting on. If it
  # fails it must not become an approved message in the mail queue that the retry sweep keeps
  # sending for hours — by then the admin has moved on and the template has probably changed.
  skips_mail_queue_capture

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
