module MembershipApplications
  class BackfillOutcomeEmails
    OUTCOME_MAILER_ACTIONS = {
      'approved' => 'application_approved',
      'rejected' => 'application_rejected'
    }.freeze

    Result = Struct.new(:linked_queued_mail, :linked_snapshot, :unmatched)

    def self.call(dry_run: false)
      new(dry_run: dry_run).call
    end

    def initialize(dry_run: false)
      @dry_run = dry_run
      @linked_queued_mail = 0
      @linked_snapshot = 0
      @unmatched = 0
    end

    def call
      excluded_queued_mail_ids = Set.new(
        MembershipApplication.where.not(outcome_queued_mail_id: nil).pluck(:outcome_queued_mail_id)
      )

      scope.find_each do |application|
        process_application!(application, excluded_queued_mail_ids)
      end

      Result.new(@linked_queued_mail, @linked_snapshot, @unmatched)
    end

    private

    attr_reader :dry_run

    def scope
      MembershipApplication.finalized
                           .where(outcome_queued_mail_id: nil, outcome_email_subject: nil)
                           .order(:id)
    end

    def process_application!(application, excluded_queued_mail_ids)
      queued_mail = find_queued_mail(application, excluded_queued_mail_ids: excluded_queued_mail_ids)
      if queued_mail
        assign_queued_mail!(application, queued_mail)
        excluded_queued_mail_ids << queued_mail.id
        @linked_queued_mail += 1
        log_line(application, "queued mail ##{queued_mail.id} (#{queued_mail.mailer_action})")
        return
      end

      mail_log_entry = find_direct_mail_log_entry(application)
      if mail_log_entry
        assign_mail_log_snapshot!(application, mail_log_entry)
        @linked_snapshot += 1
        log_line(application, "mail log entry ##{mail_log_entry.id} (#{mail_log_entry.delivery_action})")
        return
      end

      @unmatched += 1
      log_line(application, 'no matching sent outcome email found')
    end

    def assign_queued_mail!(application, queued_mail)
      return if dry_run

      OutcomeEmailRecorder.assign!(application, queued_mail)
    end

    def assign_mail_log_snapshot!(application, entry)
      return if dry_run

      application.update!(
        outcome_email_subject: entry.delivery_subject,
        outcome_email_body_html: entry.delivery_body_html
      )
    end

    def log_line(application, message)
      prefix = dry_run ? '[DRY RUN] ' : ''
      # rubocop:disable-next Rails/Output
      puts "#{prefix}Application #{application.id} (#{application.email}, #{application.status}): #{message}"
    end

    def find_queued_mail(application, excluded_queued_mail_ids:)
      action = OUTCOME_MAILER_ACTIONS[application.status]
      return nil unless action

      dest_emails = destination_emails(application)
      return nil if dest_emails.empty?

      candidates = QueuedMail
                   .where(mailer_action: action)
                   .where.not(sent_at: nil)
      candidates = candidates.where.not(id: excluded_queued_mail_ids.to_a) if excluded_queued_mail_ids.any?

      candidates = candidates.where(
        <<~SQL.squish,
          LOWER(TRIM("to")) IN (:emails)
          OR (recipient_id IS NOT NULL AND recipient_id = :recipient_id)
        SQL
        emails: dest_emails,
        recipient_id: application.user_id
      )

      pick_closest_to_review(candidates.to_a, application.reviewed_at) { |record| record.sent_at || record.created_at }
    end

    def find_direct_mail_log_entry(application)
      action = OUTCOME_MAILER_ACTIONS[application.status]
      return nil unless action

      dest_emails = destination_emails(application)
      return nil if dest_emails.empty?

      candidates = MailLogEntry
                   .where(event: 'sent', delivery_action: action)
                   .where('LOWER(TRIM(delivery_to)) IN (?)', dest_emails)
                   .order(created_at: :desc)
                   .to_a

      pick_closest_to_review(candidates, application.reviewed_at, &:created_at)
    end

    def pick_closest_to_review(records, reviewed_at, &anchor_time)
      return records.first if records.size <= 1
      return records.first if reviewed_at.blank?

      records.min_by do |record|
        anchor = anchor_time ? anchor_time.call(record) : record.created_at
        (anchor - reviewed_at).abs
      end
    end

    def destination_emails(application)
      [application.email, application.user&.email].filter_map do |email|
        normalized = email.to_s.strip.downcase
        normalized.presence
      end.uniq
    end
  end
end
