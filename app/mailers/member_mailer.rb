# Mailer for member-related notifications
# Uses database templates when available, falls back to view templates
# rubocop:disable Metrics/ClassLength -- many small mailer actions; extraction would fragment templates
class MemberMailer < ApplicationMailer
  include Rails.application.routes.url_helpers

  UrgentDigestItem = Data.define(:title, :detail, :url)

  # Sent when a new member application is submitted
  def application_received(user)
    @user = user
    @organization = organization_name

    if send_from_template('application_received', user)
      # Email sent from database template
    else
      mail(
        to: @user.email,
        subject: "#{@organization}: Application Received"
      )
    end
  end

  # Sent when a member application is approved
  def application_approved(user)
    @user = user
    @organization = organization_name

    if send_from_template('application_approved', user)
      # Email sent from database template
    else
      mail(
        to: @user.email,
        subject: "#{@organization}: Welcome! Your Application Has Been Approved"
      )
    end
  end

  # Sent when a membership application is rejected (+recipient+ may be a User or ApplicantMailRecipient)
  def application_rejected(recipient, opts = {})
    reason = opts.is_a?(Hash) ? opts[:reason] : opts
    @user = recipient
    @organization = organization_name
    @reason = reason

    extra_vars = {}
    extra_vars[:reason] = reason if reason.present?

    if send_from_template('application_rejected', recipient, extra_vars)
      # Email sent from database template
    else
      mail(
        to: recipient.email,
        subject: "#{@organization}: Update on Your Membership Application"
      )
    end
  end

  # Sent when a member's payment is past due
  def payment_past_due(user, days_overdue: nil)
    @user = user
    @organization = organization_name
    @days_overdue = days_overdue

    extra_vars = { days_overdue: days_overdue ? " by #{days_overdue} days" : '' }

    if send_from_template('payment_past_due', user, extra_vars)
      # Email sent from database template
    else
      mail(
        to: @user.email,
        subject: "#{@organization}: Payment Reminder"
      )
    end
  end

  # Sent when a membership is cancelled (voluntary or involuntary)
  def membership_cancelled(user, opts = {})
    reason = opts.is_a?(Hash) ? opts[:reason] : opts
    @user = user
    @organization = organization_name
    @reason = reason

    extra_vars = { reason: reason.present? ? "<p><strong>Reason:</strong> #{reason}</p>" : '' }

    if send_from_template('membership_cancelled', user, extra_vars)
      # Email sent from database template
    else
      mail(
        to: @user.email,
        subject: "#{@organization}: Membership Cancelled"
      )
    end
  end

  # Sent when a member is banned
  def membership_banned(user, opts = {})
    reason = opts.is_a?(Hash) ? opts[:reason] : opts
    @user = user
    @organization = organization_name
    @reason = reason

    extra_vars = { reason: reason.present? ? "<p><strong>Reason:</strong> #{reason}</p>" : '' }

    if send_from_template('membership_banned', user, extra_vars)
      # Email sent from database template
    else
      mail(
        to: @user.email,
        subject: "#{@organization}: Account Suspended"
      )
    end
  end

  def membership_lapsed(user)
    @user = user
    @organization = organization_name

    if send_from_template('membership_lapsed', user)
      # Email sent from database template
    else
      mail(
        to: @user.email,
        subject: "#{@organization}: Your Membership Dues Have Lapsed"
      )
    end
  end

  def membership_sponsored(user)
    @user = user
    @organization = organization_name

    if send_from_template('membership_sponsored', user)
      # Email sent from database template
    else
      mail(
        to: @user.email,
        subject: "#{@organization}: Your Membership Has Been Sponsored!"
      )
    end
  end

  def training_completed(user, training_topic:)
    @user = user
    @organization = organization_name
    @training_topic = training_topic

    extra_vars = { training_topic: training_topic }

    if send_from_template('training_completed', user, extra_vars)
      # Email sent from database template
    else
      mail(
        to: @user.email,
        subject: "#{@organization}: You're Now Trained in #{training_topic}!"
      )
    end
  end

  def training_requested(user, opts = {})
    assign_training_requested_instance_vars(user, opts)
    extra_vars = training_requested_template_vars
    to_address = training_requested_to_address(user, opts)

    if send_from_template('training_requested', user, extra_vars, to: to_address)
      # Email sent from database template
    else
      mail(
        to: to_address,
        subject: "#{@organization}: Training request for #{@training_topic}"
      )
    end
  end

  def trainer_capability_granted(user, training_topic:)
    @user = user
    @organization = organization_name
    @training_topic = training_topic

    extra_vars = { training_topic: training_topic }

    if send_from_template('trainer_capability_granted', user, extra_vars)
      # Email sent from database template
    else
      mail(
        to: @user.email,
        subject: "#{@organization}: You Can Now Train Others in #{training_topic}!"
      )
    end
  end

  def parking_permit_issued(user, opts = {})
    send_parking_notice_mail('parking_permit_issued', user, opts)
  end

  def parking_ticket_issued(user, opts = {})
    send_parking_notice_mail('parking_ticket_issued', user, opts)
  end

  def parking_permit_expired(user, opts = {})
    send_parking_notice_mail('parking_permit_expired', user, opts)
  end

  def parking_ticket_expired(user, opts = {})
    send_parking_notice_mail('parking_ticket_expired', user, opts)
  end

  def parking_permit_expiring_soon(user, opts = {})
    send_parking_notice_mail('parking_permit_expiring_soon', user, opts)
  end

  def parking_ticket_expiring_soon(user, opts = {})
    send_parking_notice_mail('parking_ticket_expiring_soon', user, opts)
  end

  def parking_permit_overdue_reminder(user, opts = {})
    send_parking_notice_mail('parking_permit_overdue_reminder', user, opts)
  end

  def parking_ticket_overdue_reminder(user, opts = {})
    send_parking_notice_mail('parking_ticket_overdue_reminder', user, opts)
  end

  def parking_permit_final_reminder(user, opts = {})
    send_parking_notice_mail('parking_permit_final_reminder', user, opts)
  end

  def parking_ticket_final_reminder(user, opts = {})
    send_parking_notice_mail('parking_ticket_final_reminder', user, opts)
  end

  def application_email_verification(email, opts = {})
    @email = email
    @organization = organization_name
    @verification_url = opts[:verification_url] || opts['verification_url']
    @expires_in = opts[:expires_in] || opts['expires_in'] || '24 hours'
    @notification_verification_token = opts[:verification_token] || opts['verification_token']

    mail(
      to: email,
      subject: "#{@organization}: Verify Your Email to Begin Your Membership Application"
    )
  end

  def login_link_sent(user, opts = {})
    @user = user
    @organization = organization_name
    @login_url = opts[:login_url] || opts['login_url']

    if send_from_template('login_link_sent', user, { login_url: @login_url })
      # Email sent from database template
    else
      mail(
        to: @user.email,
        subject: "#{@organization}: Your Login Link"
      )
    end
  end

  def login_link_expired(user, _opts = {})
    @user = user
    @organization = organization_name

    if send_from_template('login_link_expired', user)
      # Email sent from database template
    else
      mail(
        to: @user.email,
        subject: "#{@organization}: Your Login Link Has Expired"
      )
    end
  end

  # Notify admins of a new application (+opts+ may include +:application_url+ for that application’s admin page).
  def admin_new_application(applicant, admin_email, opts = {})
    opts = opts.symbolize_keys
    @user = applicant
    @organization = organization_name
    @admin_email = admin_email
    explicit_url = opts[:application_url].presence
    @application_url = explicit_url || membership_applications_fallback_url
    extra_vars = { application_url: @application_url }

    if send_from_template('admin_new_application', applicant, extra_vars, to: admin_email)
      # Email sent from database template
    else
      mail(
        to: admin_email,
        subject: "#{@organization}: New Member Application - #{@user.display_name}"
      )
    end
  end

  # Notify ED / Assistant ED trained staff (+deliver_later+, not QueuedMail).
  # +applicant+ comes from +QueuedMail.applicant_recipient_for(application)+.
  def staff_new_application(application, staff_email)
    applicant = QueuedMail.applicant_recipient_for(application)
    @user = applicant
    @organization = organization_name
    @application_url = membership_application_url(application)

    extra_vars = { application_url: @application_url }

    if send_from_template('staff_new_application', applicant, extra_vars, to: staff_email)
      # Email sent from database template
    else
      mail(
        to: staff_email,
        subject: "#{@organization}: New application needs review — #{applicant.display_name}"
      )
    end
  end

  # Remind ED / Associate ED trained staff about stale pending applications.
  def staff_application_reminder(application, staff_email)
    applicant = QueuedMail.applicant_recipient_for(application)
    @user = applicant
    @organization = organization_name
    @application_url = membership_application_url(application)
    @application_age_days = application_age_days(application)
    @submitted_at = application.submitted_at || application.created_at

    extra_vars = {
      application_url: @application_url,
      application_age_days: @application_age_days.to_s,
      submitted_at: @submitted_at.to_date.to_fs(:long)
    }

    if send_from_template('staff_application_reminder', applicant, extra_vars, to: staff_email)
      # Email sent from database template
    else
      mail(
        to: staff_email,
        subject: "#{@organization}: Application overdue for review - #{applicant.display_name}"
      )
    end
  end

  def slack_signup_reminder(user, opts = {})
    @user = user
    @organization = organization_name
    extras = self.class.slack_signup_template_extras(user, now: opts[:now] || Time.current)

    if send_from_template('slack_signup_reminder', user, extras)
      # Email sent from database template
    else
      @slack_link_url = extras[:slack_link_url]
      mail(
        to: @user.email,
        subject: "#{@organization}: Join us on Slack"
      )
    end
  end

  def orientation_reminder(user, opts = {})
    @user = user
    @organization = organization_name
    extras = self.class.orientation_template_extras(user, now: opts[:now] || Time.current)

    if send_from_template('orientation_reminder', user, extras)
      # Email sent from database template
    else
      @days_since_approval = extras[:days_since_approval]
      mail(
        to: @user.email,
        subject: "#{@organization}: Book your building access orientation"
      )
    end
  end

  def application_link_reminder(recipient, opts = {})
    @user = recipient
    @organization = organization_name
    @application_url = opts[:application_url] || opts['application_url']

    extra_vars = { application_url: @application_url.to_s }

    if send_from_template('application_link_reminder', recipient, extra_vars, to: recipient.email)
      # Email sent from database template
    else
      mail(
        to: recipient.email,
        subject: "#{@organization}: Complete your membership application"
      )
    end
  end

  # Warns admins when outbound mail to a banned or deceased member was blocked.
  def blocked_recipient_delivery_attempt(admin, details)
    assign_blocked_recipient_delivery_vars(admin, details.symbolize_keys)

    if send_from_template('blocked_recipient_delivery_attempt', admin, blocked_recipient_template_vars, to: admin.email)
      # Email sent from database template
    else
      mail(
        to: admin.email,
        subject: "#{@organization}: Blocked email to #{@membership_state_label.downcase} member"
      )
    end
  end

  def admin_dashboard_urgent_digest(staff, items)
    items = items.map { |item| urgent_digest_item(item) }
    @user = staff
    @organization = organization_name
    @items = items
    @dashboard_url = ENV.fetch('APP_BASE_URL', 'http://localhost:3000').chomp('/')

    extra_vars = {
      urgent_item_count: items.size.to_s,
      urgent_items_html: urgent_items_html(items),
      urgent_items_text: urgent_items_text(items),
      dashboard_url: @dashboard_url
    }

    if send_from_template('admin_dashboard_urgent_digest', staff, extra_vars, to: staff.email)
      # Email sent from database template
    else
      mail(
        to: staff.email,
        subject: "#{@organization}: #{items.size} urgent admin dashboard #{'item'.pluralize(items.size)}"
      )
    end
  end

  def message_received(message)
    @message = message
    @sender = message.sender
    @recipient = message.recipient
    @organization = organization_name

    mail(
      to: @recipient.email,
      subject: "#{@organization}: Message from #{@sender.display_name} - #{message.subject}"
    )
  end

  TRAINING_REQUEST_CONTACT_WITHHELD = 'withheld'.freeze

  # Build template variables for a user, merging in action-specific extras.
  # Public class method so QueuedMail can call it for regeneration.
  def self.build_template_variables(user, extra_args = {})
    vars = base_template_variables(user)
    merge_template_extras!(vars, extra_args)
    vars
  end

  def self.application_link_template_extras(verification)
    url_options = Rails.application.config.action_mailer.default_url_options
    application_url = Rails.application.routes.url_helpers.apply_verify_email_url(
      token: verification.token,
      **url_options
    )
    { application_url: application_url }
  end

  def self.slack_signup_template_extras(user, now: Time.current)
    anchor = user.membership_approved_at
    days = anchor ? ((now - anchor) / 1.day).floor : 0
    link_url = slack_link_url_for_template
    extras = {
      days_since_approval: days.to_s,
      slack_link_url: link_url,
      slack_link_html: '',
      slack_link_text: ''
    }

    if link_url.present?
      extras[:slack_link_html] = %(<p><a href="#{link_url}">Associate your Slack account</a></p>)
      extras[:slack_link_text] = "Associate your Slack account: #{link_url}\n\n"
    end

    extras
  end

  def self.orientation_template_extras(user, now: Time.current)
    anchor = user.membership_approved_at
    days = anchor ? ((now - anchor) / 1.day).floor : 0
    { days_since_approval: days.to_s }
  end

  def self.slack_link_url_for_template
    return '' unless SlackOidcConfig.configured?

    base = ENV.fetch('APP_BASE_URL', 'http://localhost:3000').chomp('/')
    "#{base}#{Rails.application.routes.url_helpers.slack_link_start_path}"
  end

  def self.training_request_contact_fields(user:, share_contact_info:)
    if ActiveModel::Type::Boolean.new.cast(share_contact_info)
      {
        requester_email: user.email.to_s,
        requester_slack: user.slack_handle.to_s
      }
    else
      {
        requester_email: TRAINING_REQUEST_CONTACT_WITHHELD,
        requester_slack: ''
      }
    end
  end

  def self.base_template_variables(user)
    org = ENV.fetch('ORGANIZATION_NAME', 'Member Zone')
    {
      member_name: user.display_name,
      member_email: user.email || 'Not provided',
      member_username: user.username || 'Not set',
      organization_name: org,
      date: Date.current.strftime('%B %d, %Y'),
      app_url: ENV.fetch('APP_BASE_URL', 'http://localhost:3000')
    }
  end

  def self.merge_template_extras!(vars, extra_args)
    vars[:days_overdue] = extra_args[:days_overdue] ? " by #{extra_args[:days_overdue]} days" : ''
    vars[:reason] = if extra_args[:reason].present?
                      "<p><strong>Reason:</strong> #{extra_args[:reason]}</p>"
                    else
                      ''
                    end
    vars[:training_topic] = extra_args[:training_topic] if extra_args[:training_topic].present?
    vars[:application_url] = extra_args[:application_url].to_s if extra_args.key?(:application_url)
    merge_training_request_template_keys!(vars, extra_args)
    merge_parking_notice_template_keys!(vars, extra_args)
    merge_slack_signup_template_keys!(vars, extra_args)
  end

  def self.merge_training_request_template_keys!(vars, extra_args)
    vars[:requester_name] = extra_args[:requester_name].to_s if extra_args.key?(:requester_name)
    vars[:requester_email] = extra_args[:requester_email].to_s if extra_args.key?(:requester_email)
    vars[:requester_slack] = extra_args[:requester_slack].to_s if extra_args.key?(:requester_slack)
    vars[:recipient_role] = extra_args[:recipient_role].to_s if extra_args.key?(:recipient_role)
    vars[:trainer_names] = extra_args[:trainer_names].to_s if extra_args.key?(:trainer_names)
    vars[:contact_details] = extra_args[:contact_details].to_s if extra_args.key?(:contact_details)
  end

  def self.merge_slack_signup_template_keys!(vars, extra_args)
    vars[:days_since_approval] = extra_args[:days_since_approval].to_s if extra_args.key?(:days_since_approval)
    vars[:slack_link_url] = extra_args[:slack_link_url].to_s if extra_args.key?(:slack_link_url)
    vars[:slack_link_html] = extra_args[:slack_link_html].to_s if extra_args.key?(:slack_link_html)
    vars[:slack_link_text] = extra_args[:slack_link_text].to_s if extra_args.key?(:slack_link_text)
  end

  def self.merge_parking_notice_template_keys!(vars, extra_args)
    vars[:location] = extra_args[:location].to_s if extra_args.key?(:location)
    vars[:location_detail] = extra_args[:location_detail].to_s if extra_args.key?(:location_detail)
    vars[:description] = extra_args[:description].to_s if extra_args.key?(:description)
    vars[:expires_at] = extra_args[:expires_at].to_s if extra_args.key?(:expires_at)
    vars[:notice_type] = extra_args[:notice_type].to_s if extra_args.key?(:notice_type)
  end

  class << self
    private :base_template_variables, :merge_template_extras!, :merge_training_request_template_keys!,
            :merge_slack_signup_template_keys!, :merge_parking_notice_template_keys!
  end

  private

  def assign_training_requested_instance_vars(user, opts)
    normalized = normalize_training_requested_opts(opts)
    @user = user
    @organization = organization_name
    @training_topic = normalized[:training_topic]
    @requester_name = normalized[:requester_name] || @user.display_name
    @share_contact_info = ActiveModel::Type::Boolean.new.cast(normalized[:share_contact_info])
    contact = self.class.training_request_contact_fields(user: @user, share_contact_info: @share_contact_info)
    @requester_email = normalized.key?(:requester_email) ? normalized[:requester_email].to_s : contact[:requester_email]
    @requester_slack = normalized.key?(:requester_slack) ? normalized[:requester_slack].to_s : contact[:requester_slack]
    @recipient_role = normalized[:recipient_role] || 'trainer'
    @trainer_names = normalized[:trainer_names] || ''
  end

  def training_requested_template_vars
    {
      training_topic: @training_topic,
      requester_name: @requester_name,
      requester_email: @requester_email,
      requester_slack: @requester_slack,
      recipient_role: @recipient_role,
      trainer_names: @trainer_names,
      contact_details: training_requested_contact_block
    }
  end

  def training_requested_contact_block
    lines = ["Email: #{@requester_email}"]
    lines << "Slack: #{@requester_slack}" if @share_contact_info && @requester_slack.present?
    lines.join('<br>')
  end

  def training_requested_to_address(user, opts)
    normalized = normalize_training_requested_opts(opts)
    normalized[:to] || user.email
  end

  def normalize_training_requested_opts(opts)
    opts.to_h.deep_symbolize_keys
  end

  def send_from_template(template_key, user, extra_variables = {}, mail_options = {})
    template = EmailTemplate.find_enabled(template_key)
    return false unless template

    variables = build_variables(user).merge(extra_variables)
    rendered = template.render(variables)

    to_address = mail_options[:to] || user.email
    return false if to_address.blank?

    mail(to: to_address, subject: rendered[:subject]) do |format|
      body_text = rendered[:body_text]
      footer_text = @notification_footer&.text.to_s
      body_text = "#{body_text}\n\n#{footer_text}".strip if footer_text.present? && body_text.present?
      format.html { render html: rendered[:body_html].html_safe, layout: 'mailer' }
      format.text { render plain: body_text.presence || footer_text }
    end

    true
  end

  def build_variables(user)
    {
      member_name: user.display_name,
      member_email: user.email || 'Not provided',
      member_username: user.username || 'Not set',
      organization_name: organization_name,
      date: Date.current.strftime('%B %d, %Y'),
      app_url: ENV.fetch('APP_BASE_URL', 'http://localhost:3000'),
      support_email: support_email,
      reactivation_months: MembershipSetting.reactivation_grace_period_months
    }
  end

  def membership_applications_fallback_url
    membership_applications_url
  rescue ArgumentError, ActionController::UrlGenerationError
    base = ENV.fetch('APP_BASE_URL', 'http://localhost:3000').chomp('/')
    "#{base}/membership_applications"
  end

  def application_age_days(application)
    start_at = application.submitted_at || application.created_at
    ((Time.current - start_at) / 1.day).floor
  end

  def urgent_items_html(items)
    rows = items.map do |item|
      title = ERB::Util.html_escape(item.title)
      detail = ERB::Util.html_escape(item.detail.to_s)
      url = ERB::Util.html_escape(item.url)
      detail_html = detail.present? ? "<br><span>#{detail}</span>" : ''
      %(<li><strong>#{title}</strong>#{detail_html}<br><a href="#{url}">Open in Member Zone</a></li>)
    end
    "<ul>#{rows.join}</ul>"
  end

  def urgent_items_text(items)
    items.map do |item|
      lines = ["- #{item.title}"]
      lines << "  #{item.detail}" if item.detail.present?
      lines << "  #{item.url}"
      lines.join("\n")
    end.join("\n\n")
  end

  def urgent_digest_item(item)
    return item if item.respond_to?(:title)

    UrgentDigestItem.new(
      item[:title] || item['title'],
      item[:detail] || item['detail'],
      item[:url] || item['url']
    )
  end

  def assign_blocked_recipient_delivery_vars(admin, details)
    recipient = details[:recipient]
    queued_mail = details[:queued_mail]
    @user = admin
    @organization = organization_name
    @recipient_name = recipient&.display_name || 'Unknown member'
    @delivery_to = details[:delivery_to].presence || recipient&.email || 'Unknown'
    @membership_state_label = membership_state_label_for(recipient)
    @blocked_subject = details[:subject].presence || 'Unknown subject'
    @mailer_action = details[:mailer_action].presence || 'unknown'
    @mailer_class = details[:mailer_class]
    @queued_mail_url = queued_mail_url_for(queued_mail)
  end

  def blocked_recipient_template_vars
    {
      recipient_name: @recipient_name,
      delivery_to: @delivery_to,
      membership_state_label: @membership_state_label,
      blocked_subject: @blocked_subject,
      mailer_action: @mailer_action,
      mailer_class: @mailer_class.to_s,
      queued_mail_url: @queued_mail_url.to_s
    }
  end

  def membership_state_label_for(user)
    return 'Banned or deceased' if user.blank?

    MailRecipientGuard::MEMBERSHIP_STATE_LABELS.fetch(user.membership_state, user.membership_state.humanize)
  end

  def queued_mail_url_for(queued_mail)
    return if queued_mail.blank?

    queued_mail_url(queued_mail)
  rescue ArgumentError, ActionController::UrlGenerationError
    base = ENV.fetch('APP_BASE_URL', 'http://localhost:3000').chomp('/')
    "#{base}/queued_mails/#{queued_mail.id}"
  end

  def send_parking_notice_mail(template_key, user, opts = {})
    @user = user
    @organization = organization_name

    extra_vars = {
      location: opts[:location].to_s,
      location_detail: opts[:location_detail].to_s,
      description: opts[:description].to_s,
      expires_at: opts[:expires_at].to_s,
      notice_type: opts[:notice_type].to_s
    }
    @location = extra_vars[:location]
    @location_detail = extra_vars[:location_detail]
    @description = extra_vars[:description]
    @expires_at = extra_vars[:expires_at]
    @notice_type = extra_vars[:notice_type]

    subject_label = template_key.humanize.titleize
    if send_from_template(template_key, user, extra_vars)
      # Email sent from database template
    else
      mail(
        to: @user.email,
        subject: "#{@organization}: #{subject_label}"
      )
    end
  end
end
# rubocop:enable Metrics/ClassLength
