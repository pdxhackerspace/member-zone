# frozen_string_literal: true

module MembershipApplications
  # When an Executive Director approves an application: ensure a +User+ exists (create or link),
  # mark the application approved, journal the event, and queue +application_approved+ mail.
  class FinalizeApproval
    Result = Struct.new(:status, :queued_mail, :user, :message) do
      def success?
        status == :success
      end

      def failure?
        status == :failure
      end
    end

    MAILING_ADDRESS_LABEL = 'Mailing Address'
    PHONE_NUMBER_LABEL = 'Phone number'
    CONTACT_LABELS_FOR_NOTES = [
      'Member Email',
      'Member Phone'
    ].freeze

    def self.call(application:, admin:, notes: nil)
      new(application: application, admin: admin, notes: notes).call
    end

    def initialize(application:, admin:, notes: nil)
      @application = application
      @admin = admin
      @notes = notes
    end

    def call
      precheck_error = precheck_error_message
      return failure_result(precheck_error) if precheck_error

      process_approval
    rescue ActiveRecord::RecordInvalid => e
      failure_result(e.record.errors.full_messages.to_sentence)
    rescue StandardError => e
      Rails.logger.error("[FinalizeApproval] #{e.class}: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
      failure_result(e.message)
    end

    private

    def precheck_error_message
      return 'Application has no email address.' if @application.email.to_s.strip.blank?
      return 'Draft applications cannot be approved.' if @application.draft?
      return 'This application has already been finalized.' if already_finalized?

      nil
    end

    def process_approval
      user = nil
      queued_mail = nil

      MembershipApplication.transaction do
        @application.lock!
        return failure_result('This application has already been finalized.') if already_finalized?

        user = resolve_recipient_user!
        approve_application!(user)
        queued_mail = queue_approval_mail_for(user)
        MembershipApplications::OutcomeEmailRecorder.assign!(@application, queued_mail)
      end

      success_result(user: user, queued_mail: queued_mail)
    end

    def already_finalized?
      @application.approved? || @application.rejected?
    end

    def approve_application!(user)
      @application.update!(
        status: 'approved',
        reviewed_by: @admin,
        reviewed_at: Time.current,
        admin_notes: @notes,
        user_id: user.id
      )
      # Approval makes them a member straight away; they stay active while they arrange
      # building access training. A no-op for anyone who is already a member.
      user.approve_application!
      Journal.record_application_event!(
        application: @application,
        action: 'application_approved',
        actor: @admin
      )
    end

    def queue_approval_mail_for(user)
      QueuedMail.enqueue(
        :application_approved,
        user,
        reason: 'Application approved',
        to: user.email
      )
    end

    def success_result(user:, queued_mail:)
      Result.new(:success, queued_mail, user, nil)
    end

    def failure_result(message)
      Result.new(:failure, nil, nil, message)
    end

    def resolve_recipient_user!
      return merge_application_into_user!(@application.user) if @application.user.present?

      email = @application.email.to_s.strip.downcase

      existing = User.by_any_email(email).first

      return merge_application_into_user!(existing) if existing

      User.create!(new_user_attributes(email))
    end

    def new_user_attributes(email)
      attrs = {
        email: email,
        full_name: derived_full_name,
        mailing_address: mailing_address_from_application,
        phone_number: phone_number_from_application,
        service_account: false
      }
      pn = answer_for_label('Pronouns')
      attrs[:pronouns] = pn if pn.present?
      notes = contact_notes_section
      attrs[:notes] = notes if notes.present?
      attrs.compact
    end

    def merge_application_into_user!(user)
      attrs = {}
      name = derived_full_name
      attrs[:full_name] = name if user.full_name.blank? && name.present?
      pn = answer_for_label('Pronouns')
      attrs[:pronouns] = pn if user.pronouns.blank? && pn.present?
      mailing_address = mailing_address_from_application
      attrs[:mailing_address] = mailing_address if user.mailing_address.blank? && mailing_address.present?
      phone_number = phone_number_from_application
      attrs[:phone_number] = phone_number if user.phone_number.blank? && phone_number.present?
      extra_notes = contact_notes_section
      if extra_notes.present?
        attrs[:notes] = [user.notes, "From membership application:\n#{extra_notes}"].compact.join("\n\n").strip
      end
      user.update!(attrs) if attrs.any?
      user.reload
    end

    def derived_full_name
      name = @application.applicant_display_name
      return name if name.present? && name != '—'

      local = @application.email.to_s.split('@', 2).first.to_s
      return nil if local.blank?

      local.tr('_', ' ').titleize
    end

    def answer_for_label(label)
      q = ApplicationFormQuestion.find_by(label: label)
      return nil unless q

      @application.application_answers.find_by(application_form_question: q)&.value&.strip.presence
    end

    def mailing_address_from_application
      answer_for_label(MAILING_ADDRESS_LABEL)
    end

    def phone_number_from_application
      answer_for_label(PHONE_NUMBER_LABEL)
    end

    def contact_notes_section
      lines = CONTACT_LABELS_FOR_NOTES.filter_map do |label|
        val = answer_for_label(label)
        next if val.blank?

        "#{label}: #{val}"
      end
      lines.join("\n").presence
    end
  end
end
