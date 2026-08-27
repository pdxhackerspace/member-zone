class ApplicationVerificationsController < ApplicationController
  before_action :redirect_builtin_only_requests_when_external,
                only: %i[send_verification verify_email check_email status]

  def gate
    unless MembershipSetting.use_builtin_membership_application?
      @apply_content = TextFragment.content_for('apply_for_membership')
      render :gate_external
      return
    end

    @code_of_conduct_doc = Document.find_by('LOWER(title) = ?', 'code of conduct')
  end

  def code_of_conduct_pdf
    doc = Document.find_by('LOWER(title) = ?', 'code of conduct')
    if doc&.file&.attached?
      send_data doc.file.download,
                filename: doc.file.filename.to_s,
                type: doc.file.content_type,
                disposition: 'inline'
    else
      head :not_found
    end
  end

  def send_verification
    return unless open_house_confirmation_ok?
    return unless code_of_conduct_confirmation_ok?

    email = normalized_verification_email
    return if email.nil?

    if EmailNotificationOptOut.opted_out?(email, category: 'application_link')
      @opted_out_message = TextFragment.content_for('application_email_opted_out')
      render :gate, status: :unprocessable_content
      return
    end

    verification = create_verification!(email)
    deliver_verification_mailer(email, verification)

    redirect_to apply_check_email_path
  end

  def verify_email
    verification = find_verification_for_token
    return unless verification

    application = verification.submitted_application
    if application
      verification.verify_email! unless verification.email_verified?
      redirect_to apply_application_status_path(token: verification.token)
      return
    end

    if verification.expired?
      redirect_to apply_new_path, alert: 'This verification link has expired. Please start over.'
      return
    end

    verification.verify_email!
    session[:verified_application_token] = verification.token

    redirect_to apply_start_path
  end

  def status
    verification = find_verification_for_token
    return unless verification

    @application = verification.submitted_application
    unless @application
      redirect_to apply_new_path, alert: 'No submitted application was found for this link.'
      return
    end

    verification.verify_email! unless verification.email_verified?
    @status = @application.applicant_status
    @outcome_email = MembershipApplications::OutcomeEmailRecorder.for_display(@application)
    @timing = MembershipApplications::ApplicantStatusTiming.for(@application)
  end

  def check_email; end

  private

  def redirect_builtin_only_requests_when_external
    return if MembershipSetting.use_builtin_membership_application?

    redirect_to apply_path,
                alert: 'Applications use the instructions on the apply page. Follow the link from sign-in to apply.'
  end

  def open_house_confirmation_ok?
    return true if params[:confirmed_open_house] == '1'

    redirect_to apply_new_path, alert: 'You must confirm that you have attended an open house.'
    false
  end

  def code_of_conduct_confirmation_ok?
    return true if params[:confirmed_code_of_conduct] == '1'

    redirect_to apply_new_path, alert: 'You must confirm that you have read and agree with the Code of Conduct.'
    false
  end

  def normalized_verification_email
    email = params[:email].to_s.strip.downcase
    if email.blank? || !email.match?(URI::MailTo::EMAIL_REGEXP)
      redirect_to apply_new_path, alert: 'Please enter a valid email address.'
      return
    end
    email
  end

  def create_verification!(email)
    ApplicationVerification.create!(
      email: email,
      confirmed_open_house: true,
      confirmed_code_of_conduct: true
    )
  end

  def deliver_verification_mailer(_email, verification)
    verification.deliver_verification_email!
  end

  def find_verification_for_token
    verification = ApplicationVerification.find_by(token: params[:token])
    if verification.nil?
      redirect_to apply_new_path, alert: 'Invalid verification link.'
      return nil
    end

    verification
  end
end
