class MembershipApplication < ApplicationRecord
  include SensitiveFields

  encrypts_sensitive_string :email
  has_email_lookup :email, digest_column: :email_lookup_digest

  STATUSES = %w[draft submitted under_review needs_review approved rejected].freeze
  IN_REVIEW_STATUSES = %w[under_review needs_review].freeze
  NAGGABLE_PENDING_STATUSES = %w[submitted under_review].freeze

  # Form question labels whose answers are masked (with reveal control) for viewers who do not
  # hold the applications.view_pii privilege.
  FORM_ANSWER_LABELS_CONTACT_SENSITIVE = [
    'Mailing Address',
    'Phone number',
    'Member Email',
    'Member Phone'
  ].freeze

  belongs_to :reviewed_by, class_name: 'User', optional: true
  belongs_to :user, optional: true
  belongs_to :outcome_queued_mail, class_name: 'QueuedMail', optional: true
  has_many :application_answers, dependent: :destroy
  has_many :ai_feedback_votes, -> { order(created_at: :asc) },
           class_name: 'MembershipApplicationAiFeedbackVote', dependent: :destroy
  has_many :tour_feedbacks, -> { includes(:user).order(updated_at: :desc) },
           class_name: 'MembershipApplicationTourFeedback', dependent: :destroy
  has_many :acceptance_votes, class_name: 'MembershipApplicationAcceptanceVote', dependent: :destroy

  validates :email, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :token, presence: true, uniqueness: true

  before_validation :generate_token, on: :create

  scope :drafts, -> { where(status: 'draft') }
  scope :ai_feedback_unprocessed, lambda {
    where.not(status: 'draft').where(ai_feedback_processed_at: nil)
  }
  scope :submitted_apps, -> { where(status: 'submitted') }
  scope :under_review_apps, -> { where(status: IN_REVIEW_STATUSES) }
  scope :approved, -> { where(status: 'approved') }
  scope :rejected, -> { where(status: 'rejected') }
  scope :finalized, -> { where(status: %w[approved rejected]) }
  # Applications awaiting a final decision (Open, Under Review, or parked Needs Review).
  scope :pending, -> { where(status: %w[submitted] + IN_REVIEW_STATUSES) }
  scope :naggable_pending, -> { where(status: NAGGABLE_PENDING_STATUSES) }
  scope :stale_pending, lambda { |stale_cutoff = 1.week.ago|
    naggable_pending
      .where('COALESCE(membership_applications.submitted_at, membership_applications.created_at) <= ?', stale_cutoff)
  }
  scope :awaiting_admin_reminder, lambda { |stale_cutoff = 1.week.ago, repeat_cutoff = 3.days.ago|
    stale_pending(stale_cutoff)
      .where(
        'application_reminder_sent_at IS NULL OR application_reminder_sent_at <= ?',
        repeat_cutoff
      )
  }
  # Newest by when the application was submitted (or created if not yet submitted); tie-break on id for stable ordering.
  scope :newest_first, lambda {
    reorder(
      Arel.sql(
        'COALESCE(membership_applications.submitted_at, membership_applications.created_at) DESC NULLS LAST'
      ),
      Arel.sql('membership_applications.id DESC')
    )
  }
  # rubocop:disable-next Metrics/BlockLength
  scope :admin_search, lambda { |query|
    raw = query.to_s.strip
    if raw.blank?
      all
    else
      pattern = "%#{ActiveRecord::Base.sanitize_sql_like(raw.downcase)}%"
      matches = where(
        <<~SQL.squish,
          EXISTS (
            SELECT 1 FROM application_answers aa
            WHERE aa.membership_application_id = membership_applications.id
            AND LOWER(aa.value) LIKE :p
          )
          OR EXISTS (
            SELECT 1 FROM users u
            WHERE u.id = membership_applications.user_id
            AND (
              LOWER(COALESCE(u.full_name, '')) LIKE :p
              OR LOWER(COALESCE(u.username, '')) LIKE :p
            )
          )
        SQL
        p: pattern
      )
      email_digest = SensitiveData.email_digest(raw)
      if email_digest.present?
        matches = matches.or(where(email_lookup_digest: email_digest))
                         .or(where('LOWER(email) = ?', SensitiveData.normalize_email(raw)))
                         .or(where(user_id: User.by_any_email(raw).select(:id)))
      end
      matches
    end
  }

  def draft?
    status == 'draft'
  end

  def submitted?
    status == 'submitted'
  end

  def under_review?
    status == 'under_review'
  end

  def needs_review?
    status == 'needs_review'
  end

  def in_review?
    under_review? || needs_review?
  end

  def approved?
    status == 'approved'
  end

  def rejected?
    status == 'rejected'
  end

  def pending?
    submitted? || in_review?
  end

  def linkable_to_member?
    user.nil? && !pending?
  end

  def submit!
    update!(status: 'submitted', submitted_at: Time.current)
    Journal.record_application_event!(application: self, action: 'application_submitted')
    MembershipApplicationAiFeedbackJob.perform_later(id)
    MembershipApplications::NotifyDirectorsOfSubmission.call(self)
  end

  # Updates status and journal only. The web UI uses +MembershipApplications::FinalizeApproval+ instead
  # (creates or links a +User+, queues +application_approved+ mail).
  def approve!(admin, notes: nil)
    update!(
      status: 'approved',
      reviewed_by: admin,
      reviewed_at: Time.current,
      admin_notes: notes
    )
    Journal.record_application_event!(application: self, action: 'application_approved', actor: admin)
  end

  # Marks the application rejected, journals, and queues or immediately sends the applicant rejection email.
  # Returns the new +QueuedMail+, +QueuedMail::ImmediateDelivery+, or +nil+ if no message was sent.
  def reject!(admin, notes: nil)
    queued_mail = nil
    MembershipApplication.transaction do
      update!(
        status: 'rejected',
        reviewed_by: admin,
        reviewed_at: Time.current,
        admin_notes: notes
      )
      Journal.record_application_event!(application: self, action: 'application_rejected', actor: admin)
      queued_mail = QueuedMail.enqueue_application_rejected(self, reason: notes.presence)
      MembershipApplications::OutcomeEmailRecorder.assign!(self, queued_mail)
    end
    queued_mail
  end

  # Marks the application as delayed for executive review (no applicant email).
  def delay_for_review!(admin, notes: nil)
    raise ArgumentError, 'Only open applications can be delayed for review' unless submitted?

    update!(
      status: 'under_review',
      reviewed_by: admin,
      reviewed_at: Time.current,
      admin_notes: notes
    )
    Journal.record_application_event!(application: self, action: 'application_delayed_for_review', actor: admin)
  end

  # Parks the application indefinitely: no staff nags, no acceptance votes, no applicant email.
  def mark_needs_review!(admin, notes: nil)
    raise ArgumentError, 'Only open applications can be marked needs review' unless submitted?

    update!(
      status: 'needs_review',
      reviewed_by: admin,
      reviewed_at: Time.current,
      admin_notes: notes
    )
    Journal.record_application_event!(application: self, action: 'application_marked_needs_review', actor: admin)
  end

  def status_display
    return 'Open' if submitted?
    return 'Under review' if under_review?
    return 'Needs review' if needs_review?

    status&.titleize
  end

  def status_badge_color
    case status
    when 'submitted' then 'primary'
    when 'under_review', 'needs_review' then 'warning'
    when 'approved' then 'success'
    when 'rejected' then 'danger'
    else 'secondary'
    end
  end

  def answer_for(question)
    application_answers.find_by(application_form_question: question)
  end

  # Display name for admin lists: "Name" on the first form page, then linked member, else em dash.
  def applicant_display_name(name_question_id: nil)
    qid = name_question_id
    if qid.nil?
      name_q_scope = ApplicationFormQuestion.joins(:application_form_page)
      qid = name_q_scope.where(application_form_pages: { position: 1 }, label: 'Name').pick(:id)
    end
    if qid
      ans = application_answers.detect { |a| a.application_form_question_id == qid }
      name = ans&.value&.strip
      return name if name.present?
    end
    user&.display_name.presence || '—'
  end

  # Returns answers grouped by page for display
  def answers_by_page
    ApplicationFormPage.ordered.includes(:questions).map do |page|
      questions_with_answers = page.questions.ordered.map do |q|
        { question: q, answer: answer_for(q) }
      end
      { page: page, questions: questions_with_answers }
    end
  end

  # Plain-text bundle of the application for LLM prompts (email + Q&A by page).
  def application_text_for_ai
    lines = ["Email: #{email}"]
    answers_by_page.each do |entry|
      lines << "\n## #{entry[:page].title}"
      entry[:questions].each do |h|
        q = h[:question]
        a = h[:answer]
        lines << "Q: #{q.label}"
        lines << "A: #{a&.value.presence || '(no answer)'}"
      end
    end
    lines.join("\n")
  end

  def ai_feedback_processed?
    ai_feedback_processed_at.present?
  end

  def ai_feedback_admin_vote_counts
    # Default association order(:created_at) breaks GROUP BY under PostgreSQL.
    ai_feedback_votes.unscope(:order).group(:stance).count
  end

  def acceptance_vote_counts
    acceptance_votes.group(:decision).count
  end

  def acceptance_vote_open?
    !approved? && !rejected? && !needs_review?
  end

  AI_FEEDBACK_REC_BADGES = {
    'accept' => 'success', 'accepted' => 'success', 'approve' => 'success', 'approved' => 'success',
    'reject' => 'danger', 'rejected' => 'danger', 'deny' => 'danger', 'denied' => 'danger',
    'needs_review' => 'warning', 'need_more_info' => 'warning', 'clarify' => 'warning', 'uncertain' => 'warning'
  }.freeze

  # Bootstrap badge color for +ai_feedback_recommendation+ (free-form model output).
  def ai_feedback_recommendation_badge_color
    key = ai_feedback_recommendation.to_s.downcase.strip.tr(' ', '_')
    AI_FEEDBACK_REC_BADGES.fetch(key, 'secondary')
  end

  def applicant_status
    MembershipApplications::ApplicantStatus.for(self)
  end

  def status_page_verification
    return nil if draft?

    ApplicationVerification.by_email(email).newest_first.first
  end

  private

  def generate_token
    self.token ||= SecureRandom.alphanumeric(32)
  end
end
