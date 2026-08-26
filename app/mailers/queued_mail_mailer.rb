class QueuedMailMailer < ApplicationMailer
  skip_after_action :set_member_zone_mail_trace_headers
  after_action :mark_skip_duplicate_mail_log

  def deliver_queued(queued_mail)
    @body_html = queued_mail.body_html
    @body_text = queued_mail.body_text
    assign_queued_notification_footer(queued_mail)

    mail(to: queued_mail.to, subject: queued_mail.subject) do |format|
      format.html { render html: @body_html.html_safe, layout: 'mailer' }
      format.text { render plain: @body_text } if @body_text.present?
    end
  end

  private

  def assign_notification_footer_context
    # Footer is assigned from queued mail metadata in +deliver_queued+.
  end

  def assign_queued_notification_footer(queued_mail)
    verification_token = verification_token_for(queued_mail)
    @notification_footer = Notifications::DeliveryGate.footer_for(
      mailer_action: queued_mail.mailer_action,
      user: queued_mail.recipient,
      email: queued_mail.to,
      verification_token: verification_token
    )
    footer_text = @notification_footer.text
    @body_text = "#{@body_text}\n\n#{footer_text}".strip if footer_text.present? && @body_text.present?
  end

  def verification_token_for(queued_mail)
    verification_id = queued_mail.mailer_args&.dig('application_verification_id')
    return if verification_id.blank?

    ApplicationVerification.find_by(id: verification_id)&.token
  end

  def mark_skip_duplicate_mail_log
    headers['X-MemberZone-Skip-MailLog'] = '1'
  end
end
