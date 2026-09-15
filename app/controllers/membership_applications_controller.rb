class MembershipApplicationsController < ApplicationController
  require 'csv'

  include Pagy::Method
  include MembershipApplicationWizard
  include MembershipApplicationWizard::Actions
  include InitiatedApplicationActions
  include MembershipApplicationPrivileges

  before_action :require_submitted_for_review_parking!, only: %i[delay_for_review mark_needs_review]
  before_action :require_pending_application_for_acceptance_vote!, only: :vote_acceptance

  def import
    if params[:file].blank?
      redirect_to membership_applications_path, alert: 'Please choose a CSV file to import.'
      return
    end

    result = MembershipApplications::CsvImporter.new(imported_by: current_user).call(params[:file])
    notice_parts = ["Imported #{result[:imported]} application(s)."]
    notice_parts << "#{result[:skipped]} row(s) skipped." if result[:skipped].positive?
    if result[:errors].any?
      msg = result[:errors].first(5).join(' ')
      flash[:alert] = result[:errors].size > 5 ? "#{msg} …" : msg
    end
    redirect_to membership_applications_path, notice: notice_parts.join(' ')
  rescue CSV::MalformedCSVError => e
    redirect_to membership_applications_path, alert: "Invalid CSV: #{e.message}"
  end

  def index
    @current_status = params[:status].presence || 'submitted'
    @status_counts = membership_application_status_counts
    @processing_time_stats = MembershipApplications::ProcessingTimeStats.call

    if @current_status == 'initiated'
      load_initiated_applications
      return
    end

    base_scope = MembershipApplication.where.not(status: 'draft')
    @applications = base_scope.includes(:user, :reviewed_by, :application_answers, :acceptance_votes)
    @applications = case @current_status
                    when 'all'
                      @applications
                    when 'unlinked'
                      @applications.where(user_id: nil).where(status: 'approved')
                    when 'under_review'
                      @applications.where(status: MembershipApplication::IN_REVIEW_STATUSES)
                    else
                      @applications.where(status: @current_status)
                    end
    @applications = @applications.admin_search(params[:q])
    @applications = @applications.newest_first

    @pagy, @applications = pagy(@applications, limit: 25)

    load_applications_index_metadata
  end

  def show
    @pages_with_answers = @application.answers_by_page
    @users_for_application_link = linkable_users_for_show
    vote = @application.ai_feedback_votes.detect { |v| v.user_id == current_user.id }
    @current_ai_feedback_vote = vote || @application.ai_feedback_votes.build(user: current_user)
    tf = @application.tour_feedbacks.detect { |f| f.user_id == current_user.id }
    @current_tour_feedback = tf || @application.tour_feedbacks.build(user: current_user)
    av = @application.acceptance_votes.detect { |v| v.user_id == current_user.id }
    # Use `new` not `build` — a blank vote was shown as "Reject" in the tally list.
    @current_acceptance_vote = av || MembershipApplicationAcceptanceVote.new(
      membership_application: @application,
      user: current_user
    )
  end

  def link_user
    unless @application.linkable_to_member?
      redirect_to membership_application_path(@application),
                  alert: 'Open and under-review applications cannot be linked to member accounts.'
      return
    end

    user = User.non_service_accounts.find(params[:user_id])
    @application.update!(user: user)
    redirect_to membership_application_path(@application),
                notice: "Application linked to #{user.display_name}."
  end

  def unlink_user
    @application.update!(user: nil)
    redirect_to membership_application_path(@application),
                notice: 'Member link removed from this application.'
  end

  def save_tour_feedback
    if @application.draft?
      redirect_to membership_application_path(@application),
                  alert: 'Tour feedback is available after the application is submitted.'
      return
    end

    feedback = @application.tour_feedbacks.find_or_initialize_by(user: current_user)
    feedback.assign_attributes(tour_feedback_params)
    if feedback.save
      redirect_to membership_application_path(@application),
                  notice: 'Tour feedback saved.'
    else
      redirect_to membership_application_path(@application),
                  alert: feedback.errors.full_messages.to_sentence
    end
  end

  def vote_acceptance
    vote = @application.acceptance_votes.find_or_initialize_by(user: current_user)
    vote.assign_attributes(acceptance_vote_params)
    if vote.save
      redirect_to membership_application_path(@application),
                  notice: 'Your acceptance vote was saved.'
    else
      redirect_to membership_application_path(@application),
                  alert: vote.errors.full_messages.to_sentence
    end
  end

  def approve
    notes = params[:admin_notes]
    result = MembershipApplications::FinalizeApproval.call(
      application: @application,
      admin: current_user,
      notes: notes
    )

    if result.failure?
      redirect_to membership_application_path(@application), alert: result.message
      return
    end

    path, notice = outcome_email_destination(result.queued_mail, 'Application approved.', 'welcome email')
    redirect_to path, notice: notice
  end

  def reject
    notes = params[:admin_notes]
    delivery = @application.reject!(current_user, notes: notes)

    path, notice = outcome_email_destination(delivery, 'Application rejected.', 'rejection email')
    redirect_to path, notice: notice
  end

  def delay_for_review = review_parking!(:delay_for_review!, 'Application marked as under review.')

  def mark_needs_review = review_parking!(:mark_needs_review!, 'Application marked as needs review.')

  def vote_ai_feedback
    unless @application.ai_feedback_processed?
      redirect_to membership_application_path(@application),
                  alert: 'Admin feedback is only available after AI feedback has been processed.'
      return
    end

    vote = @application.ai_feedback_votes.find_or_initialize_by(user: current_user)
    vote.assign_attributes(ai_feedback_vote_params)
    if vote.save
      redirect_to membership_application_path(@application),
                  notice: 'Your feedback on the AI review was saved.'
    else
      redirect_to membership_application_path(@application),
                  alert: vote.errors.full_messages.to_sentence
    end
  end

  private

  # Where to send the admin after approving or rejecting, given what became of the outcome email:
  # held for review (go edit it), sent, queued for retry because email was unavailable (nothing to
  # review — the sweep will send it), or never raised at all.
  def outcome_email_destination(delivery, prefix, label)
    application_path = membership_application_path(@application)

    case delivery
    when QueuedMail
      if delivery.queued_for_retry?
        [application_path, "#{prefix} The #{label} could not be sent yet, so it is waiting in the " \
                           'mail queue and will be retried automatically.']
      else
        [edit_queued_mail_path(delivery),
         "#{prefix} Review and edit the queued #{label}, then approve it in the mail queue to send."]
      end
    when QueuedMail::ImmediateDelivery
      [application_path, "#{prefix} The #{label} was sent immediately to #{delivery.to}."]
    else
      [application_path, "#{prefix} No #{label} was queued (recipient has no email address)."]
    end
  end

  def membership_application_status_counts
    {
      all: MembershipApplication.where.not(status: 'draft').count,
      initiated: ApplicationVerification.count,
      submitted: MembershipApplication.submitted_apps.count,
      under_review: MembershipApplication.under_review_apps.count,
      approved: MembershipApplication.approved.count,
      rejected: MembershipApplication.rejected.count,
      unlinked: MembershipApplication.where(status: 'approved').where(user_id: nil).count
    }
  end

  def load_initiated_applications
    @applications = MembershipApplication.none
    @users_for_application_link = []
    verifications = ApplicationVerification.admin_search(params[:q]).newest_first
    @pagy, @application_verifications = pagy(verifications, limit: 25)

    emails = @application_verifications.map { |verification| verification.email.downcase }.uniq
    email_digests = SensitiveData.email_digests(emails)
    @received_applications_by_email = MembershipApplication
                                      .where.not(status: 'draft')
                                      .where('email_lookup_digest IN (:digests) OR LOWER(email) IN (:emails)',
                                             digests: email_digests.presence || [''],
                                             emails: emails.presence || [''])
                                      .newest_first
                                      .group_by { |application| application.email.downcase }
    @verification_mail_logs_by_email = MailLogEntry
                                       .where(delivery_action: 'application_email_verification')
                                       .where('LOWER(delivery_to) IN (?)', emails.presence || [''])
                                       .newest_first
                                       .group_by { |entry| entry.delivery_to.downcase }
  end

  def load_applications_index_metadata
    name_q_scope = ApplicationFormQuestion.joins(:application_form_page)
    @applicant_name_question_id = name_q_scope.where(application_form_pages: { position: 1 }, label: 'Name').pick(:id)
    @users_for_application_link = linkable_users_for_index
  end

  def linkable_users_for_index
    return [] if %w[submitted under_review].include?(@current_status)

    User.non_service_accounts.ordered_by_display_name.to_a
  end

  def linkable_users_for_show
    return [] unless @application.linkable_to_member?

    User.non_service_accounts.ordered_by_display_name.to_a
  end

  def review_parking!(method, notice)
    @application.public_send(method, current_user, notes: params[:admin_notes])
    redirect_to membership_application_path(@application), notice: notice
  end

  def require_submitted_for_review_parking!
    return if @application.submitted?

    redirect_to membership_application_path(@application),
                alert: 'Only open applications can be parked for review.'
  end

  def require_pending_application_for_acceptance_vote!
    return if @application.acceptance_vote_open?

    redirect_to membership_application_path(@application),
                alert: 'Acceptance votes can only be cast while the application is pending.'
  end

  def tour_feedback_params
    params.expect(tour_feedback: %i[attitude impressions engagement fit_feeling])
  end

  def acceptance_vote_params
    params.expect(acceptance_vote: %i[decision comment])
  end

  def ai_feedback_vote_params
    params.expect(ai_feedback_vote: %i[stance reason])
  end

  def set_application_admin
    rel = MembershipApplication
    if action_name == 'show'
      rel = rel.includes(ai_feedback_votes: :user, tour_feedbacks: :user, acceptance_votes: :user)
    end
    @application = rel.find(params[:id])
  end
end
