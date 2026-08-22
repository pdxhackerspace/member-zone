class InvitationsController < AuthenticatedController
  before_action -> { require_privilege!(:'invitations.view') }, only: :index
  before_action -> { require_privilege!(:'invitations.create') }, only: %i[new create]
  before_action -> { require_privilege!(:'invitations.cancel') }, only: :cancel

  def index
    @invitations = Invitation.newest_first.includes(:invited_by, :user)
  end

  def new
    @invitation = Invitation.new(membership_type: 'member')
    @expiry_hours = MembershipSetting.instance.invitation_expiry_hours
  end

  def create
    @invitation = Invitation.new(
      email: params[:invitation][:email]&.strip,
      membership_type: params[:invitation][:membership_type],
      invited_by: current_user
    )

    if @invitation.save
      enqueue_invitation_email(@invitation)
      # Sending an invitation does not imply being able to see the mail queue — Front desk
      # holds invitations.create and nothing else here — so land somewhere the actor can
      # actually open.
      redirect_to after_create_path,
                  notice: "#{@invitation.type_label} invitation queued " \
                          "for #{@invitation.email}. Review and approve it to send."
    else
      @expiry_hours = MembershipSetting.instance.invitation_expiry_hours
      render :new, status: :unprocessable_content
    end
  end

  def cancel
    @invitation = Invitation.find(params[:id])
    if @invitation.accepted?
      redirect_to invitations_path, alert: 'This invitation has already been accepted and cannot be cancelled.'
    elsif @invitation.cancelled?
      redirect_to invitations_path, alert: 'This invitation has already been cancelled.'
    else
      @invitation.cancel!
      redirect_to invitations_path, notice: "Invitation to #{@invitation.email} has been cancelled."
    end
  end

  private

  def after_create_path
    return queued_mails_path if can?(:'queued_mail.view')
    return invitations_path if can?(:'invitations.view')

    root_path
  end

  def enqueue_invitation_email(invitation)
    template = EmailTemplate.find_enabled('member_invitation')
    org = ENV.fetch('ORGANIZATION_NAME', 'Member Zone')

    variables = {
      organization_name: org,
      date: Date.current.strftime('%B %d, %Y'),
      app_url: ENV.fetch('APP_BASE_URL', 'http://localhost:3000'),
      invitation_url: invitation.invitation_url,
      invitation_expiry: humanize_expiry(invitation.expires_at),
      invitation_type: invitation.type_label,
      invitation_type_details: invitation.type_description
    }

    if template
      rendered = template.render(variables)
      mail = QueuedMail.create!(
        to: invitation.email,
        subject: rendered[:subject],
        body_html: rendered[:body_html],
        body_text: rendered[:body_text] || '',
        reason: "#{invitation.type_label} invitation for #{invitation.email}",
        email_template: template,
        mailer_action: 'member_invitation',
        mailer_args: { invitation_id: invitation.id }
      )
    else
      mail = QueuedMail.create!(
        to: invitation.email,
        subject: "#{org}: You're Invited to Join as a #{invitation.type_label}!",
        body_html: "<p>You've been invited to join #{org} as a " \
                   "<strong>#{invitation.type_label}</strong>.</p>" \
                   "<p>#{invitation.type_description}</p>" \
                   "<p><a href=\"#{invitation.invitation_url}\">" \
                   'Click here to create your account</a></p>' \
                   '<p>This invitation expires ' \
                   "#{humanize_expiry(invitation.expires_at)}.</p>",
        body_text: "You've been invited to join #{org} as a " \
                   "#{invitation.type_label}.\n\n" \
                   "#{invitation.type_description}\n\n" \
                   "Create your account: #{invitation.invitation_url}\n\n" \
                   'This invitation expires ' \
                   "#{humanize_expiry(invitation.expires_at)}.",
        reason: "#{invitation.type_label} invitation for #{invitation.email}",
        mailer_action: 'member_invitation',
        mailer_args: { invitation_id: invitation.id }
      )
    end

    MailLogEntry.log!(mail, 'created', details: "Queued #{invitation.type_label} invitation to #{invitation.email}")
    MailRecipientGuard.block_delivery_to!(mail)
  end

  def humanize_expiry(time)
    distance = time - Time.current
    if distance > 1.day
      "in #{(distance / 1.day).round} days"
    elsif distance > 1.hour
      "in #{(distance / 1.hour).round} hours"
    else
      "in #{(distance / 1.minute).round} minutes"
    end
  end

  def humanize_hours(hours)
    if hours >= 24 && (hours % 24).zero?
      "#{hours / 24} #{'day'.pluralize(hours / 24)}"
    else
      "#{hours} #{'hour'.pluralize(hours)}"
    end
  end
end
