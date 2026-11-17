module Metrics
  # The work the organization does through the app: applications, mail, parking, incidents,
  # credentials, API tokens, payments, and how much of everything there is.
  class ActivityCollector < Collector
    COUNTED_MODELS = %w[
      AccessLog AuditLogEntry Document Invitation Journal MailLogEntry Message PaymentEvent Rfid
      Training TrainingRequest TrainingTopic
    ].freeze

    def collect
      statuses
      mail
      api_tokens
      payments
      building_access
      record_counts
    end

    private

    def statuses
      gauge('memberzone_membership_applications', 'Membership applications by status.')
        .set_grouped(with_zeros(MembershipApplication.group(:status).count, MembershipApplication::STATUSES), :status)
      gauge('memberzone_parking_notices', 'Parking notices by type and status.')
        .set_grouped(ParkingNotice.group(:notice_type, :status).count, :notice_type, :status)
      gauge('memberzone_incident_reports', 'Incident reports by status.')
        .set_grouped(IncidentReport.group(:status).count, :status)
      gauge('memberzone_credentials', 'Issued credentials by status.')
        .set_grouped(with_zeros(Credential.group(:status).count, Credential::STATUSES), :status)
    end

    def mail
      gauge('memberzone_queued_mails', 'Queued mail by review status.')
        .set_grouped(with_zeros(QueuedMail.group(:status).count, QueuedMail::STATUSES), :status)
      unsent = QueuedMail.where(sent_at: nil).where.not(status: 'rejected')
      gauge('memberzone_queued_mails_unsent', 'Queued mail not rejected and not yet sent.', unsent.count)
      gauge('memberzone_queued_mails_failing', 'Unsent queued mail whose last delivery attempt failed.',
            unsent.where.not(last_error_at: nil).count)
      gauge('memberzone_queued_mail_oldest_unsent_timestamp_seconds',
            'When the oldest unsent queued mail was created.', unsent.minimum(:created_at))
    end

    # Mirrors ApiToken#state: revoked wins over suspended, suspended over expired. One instant for
    # both sides of the expiry line, and active is what is left, so the four always sum to the total.
    def api_tokens
      now = Time.current
      revoked = ApiToken.revoked.count
      suspended = ApiToken.suspended.count
      expired = ApiToken.expired(now).where(suspended_at: nil).count
      active = ApiToken.count - revoked - suspended - expired
      gauge('memberzone_api_tokens', 'API tokens by state.')
        .set_grouped({ 'active' => active, 'suspended' => suspended, 'expired' => expired, 'revoked' => revoked },
                     :state)
      gauge('memberzone_api_tokens_used_24h', 'API tokens used in the last 24 hours.',
            ApiToken.where(last_used_at: 1.day.ago..).count)
    end

    def payments
      gauge('memberzone_payment_events', 'Payment events by source and type.')
        .set_grouped(PaymentEvent.group(:source, :event_type).count, :source, :event_type)
      gauge('memberzone_payment_event_last_timestamp_seconds', 'When the most recent payment event occurred.',
            PaymentEvent.maximum(:occurred_at))
    end

    def building_access
      gauge('memberzone_access_log_last_timestamp_seconds', 'When the most recent building access was logged.',
            AccessLog.maximum(:logged_at))
      gauge('memberzone_access_logs_24h', 'Building access log entries in the last 24 hours.',
            AccessLog.where(logged_at: 1.day.ago..).count)
    end

    def record_counts
      family = gauge('memberzone_records', 'Rows in a table.')
      COUNTED_MODELS.each do |name|
        model = name.constantize
        family.set(model.count, table: model.table_name)
      end
    end
  end
end
