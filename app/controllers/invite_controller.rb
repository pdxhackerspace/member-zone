class InviteController < ApplicationController
  before_action :find_invitation
  before_action :check_invitation_valid, only: %i[show accept]

  def show
    return if performed?

    @user = User.new
  end

  def accept
    return if performed?

    @user = User.new(user_params)
    @user.email = @invitation.email
    # Invitation#accept! moves them to their sponsored or guest state once saved.
    @user.membership_state = User.initial_membership_state

    if @user.full_name.blank?
      @user.errors.add(:full_name, "can't be blank")
      render :show, status: :unprocessable_content
      return
    end

    if @user.save
      @invitation.accept!(@user)

      Journal.create!(
        user: @user,
        actor_user: @invitation.invited_by,
        action: 'invitation_accepted',
        changes_json: {
          'invitation' => {
            'type' => @invitation.type_label,
            'invited_by' => @invitation.invited_by.display_name,
            'accepted_at' => Time.current.iso8601
          }
        },
        changed_at: Time.current,
        highlight: true
      )

      session[:user_id] = @user.id
      redirect_to profile_setup_path,
                  notice: "Welcome to #{ENV.fetch('ORGANIZATION_NAME', 'Member Zone')}! Let's set up your profile."
    else
      render :show, status: :unprocessable_content
    end
  end

  def accepted
    if @invitation.nil?
      @error = :not_found
      render :show
      return
    end

    unless @invitation.accepted?
      redirect_to invite_path(@invitation.token)
      return
    end

    @user = @invitation.user
  end

  private

  def find_invitation
    @invitation = Invitation.find_by(token: params[:token])
  end

  def check_invitation_valid
    if @invitation.nil?
      @error = :not_found
    elsif @invitation.accepted?
      handle_already_accepted_invitation
      return
    elsif @invitation.cancelled?
      @error = :cancelled
    elsif @invitation.expired?
      @error = :expired
    end

    render :show if @error && !performed?
  end

  def handle_already_accepted_invitation
    return if performed?

    user = @invitation.user
    if user.present?
      session[:user_id] = user.id
      redirect_to root_path, notice: "Welcome back! You're already signed in."
    else
      @error = :already_accepted
      render :show
    end
  end

  def user_params
    params.expect(user: %i[full_name username])
  end
end
