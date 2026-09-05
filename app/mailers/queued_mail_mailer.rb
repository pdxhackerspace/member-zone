class QueuedMailMailer < ApplicationMailer
  skip_after_action :set_member_zone_mail_trace_headers
  after_action :mark_skip_duplicate_mail_log

  def deliver_queued(queued_mail)
    @queued_mail = queued_mail
    @notification_mailer_action = queued_mail.mailer_action
    @notification_recipient_user = queued_mail.recipient
    @body_html = queued_mail.body_html
    @body_text = queued_mail.body_text
    assign_queued_notification_footer(queued_mail)

    mail(to: queued_mail.to, subject: queued_mail.subject) do |format|
      if queued_mail.pre_rendered_mail_body?
        format.html { render html: @body_html.html_safe, layout: false }
        plain = @body_text.presence || plain_text_email_body(nil)
      else
        format.html { render html: @body_html.html_safe, layout: 'mailer' }
        plain = plain_text_email_body(@body_text)
      end
      format.text { render plain: plain } if plain.present?
    end
  end

  private

  def assign_notification_footer_context
    # Footer is assigned from queued mail metadata in +deliver_queued+.
  end

  def assign_queued_notification_footer(queued_mail)
    @notification_footer = Notifications::DeliveryGate.footer_for(
      mailer_action: queued_mail.mailer_action,
      user: queued_mail.recipient,
      email: queued_mail.to,
      verification_token: queued_mail.application_verification_token
    )
  end

  def mark_skip_duplicate_mail_log
    headers['X-MemberZone-Skip-MailLog'] = '1'
  end
end
