class EmailTemplateMailer < ApplicationMailer
  RenderedMail = Data.define(:to, :subject, :body_html, :body_text, :mailer_action, :user, :verification_token)

  def send_rendered(rendered)
    @notification_mailer_action = rendered.mailer_action
    @notification_recipient_user = rendered.user if rendered.user.is_a?(User)
    @email = rendered.to
    @notification_verification_token = rendered.verification_token
    @body_html = rendered.body_html
    @body_text = rendered.body_text

    mail(to: rendered.to, subject: rendered.subject) do |format|
      format.html { render html: @body_html.html_safe, layout: 'mailer' }
      plain = plain_text_email_body(@body_text)
      format.text { render plain: plain } if plain.present?
    end
  end
end
