class EmailTemplate
  # Sample values for every variable the default templates use, for the admin preview.
  #
  # +EmailTemplate#substitute_variables+ strips tokens it has no value for, so a variable missing
  # from here does not show up as an obvious gap in the preview — the sentence around it silently
  # loses a word. +EmailTemplatePreviewVariablesTest+ walks +DEFAULT_TEMPLATES+ and fails when a
  # token has no sample, which is the only reliable guard against that.
  module PreviewVariables
    module_function

    def all
      member
        .merge(membership)
        .merge(applications)
        .merge(invitations)
        .merge(training)
        .merge(slack)
        .merge(lapsed_access)
        .merge(admin_dashboard)
        .merge(blocked_recipient)
    end

    def member
      {
        member_name: 'John Doe',
        member_email: 'john.doe@example.com',
        member_username: 'johndoe',
        organization_name: ENV.fetch('ORGANIZATION_NAME', 'Member Zone'),
        date: Date.current.strftime('%B %d, %Y'),
        app_url: app_base_url
      }
    end

    def membership
      {
        days_overdue: ' by 14 days',
        reason: '<p><strong>Reason:</strong> Example reason</p>',
        support_email: 'info@example.com'
      }
    end

    def applications
      {
        application_url: "#{app_base_url}/membership_applications/1",
        application_age_days: '8',
        submitted_at: 8.days.ago.to_date.to_fs(:long),
        days_since_approval: '10'
      }
    end

    def invitations
      {
        invitation_url: "#{app_base_url}/invite/sample-token-abc123",
        invitation_expiry: 'in 3 days',
        invitation_type: 'Sponsored Member',
        invitation_type_details: 'Sponsored membership — full access including building access, no dues required.'
      }
    end

    def training
      {
        training_topic: 'Laser Cutter',
        requester_name: 'Alex Example',
        requester_email: 'alex@example.com',
        requester_slack: '@alex',
        recipient_role: 'trainer',
        trainer_names: 'Trainer One, Trainer Two',
        contact_details: 'Email: alex@example.com<br>Slack: alex'
      }
    end

    # Built by the mailer rather than copied from it. The plain-text fragment carries a trailing
    # blank line that the template depends on, which is easy to leave out of a hand-written sample
    # and silent when it is missing: the preview glues the link onto the sentence after it.
    def slack
      link_url = "#{app_base_url}/slack/link"

      { slack_link_url: link_url }.merge(MemberMailer.slack_link_fragments(link_url))
    end

    # The multi-visit wording is the point of this reminder, so the preview shows that shape rather
    # than a single visit an admin might mistake for the only case.
    def lapsed_access
      {
        access_summary: '3 times between April 24 and April 27',
        lapsed_at: 'March 15, 2026',
        profile_url: "#{app_base_url}/users/johndoe",
        reactivation_months: '12',
        reactivation_guidance_html: '<strong>You can reactivate without reapplying</strong> by choosing a ' \
                                    'membership plan on your profile until March 15, 2027.',
        reactivation_guidance_text: 'You can reactivate without reapplying by choosing a membership plan on ' \
                                    'your profile until March 15, 2027.'
      }
    end

    def admin_dashboard
      {
        urgent_item_count: '2',
        urgent_items_html: '<ul><li><strong>1 access controller issue</strong><br><span>1 offline</span></li></ul>',
        urgent_items_text: "- 1 access controller issue\n  1 offline",
        dashboard_url: app_base_url
      }
    end

    def blocked_recipient
      {
        membership_state_label: 'banned',
        recipient_name: 'Jane Doe',
        delivery_to: 'jane.doe@example.com',
        blocked_subject: 'Member Zone: Your dues are past due',
        mailer_action: 'payment_past_due',
        queued_mail_url: "#{app_base_url}/queued_mails/1"
      }
    end

    def app_base_url
      ENV.fetch('APP_BASE_URL', 'http://localhost:3000')
    end
  end
end
