class ProfileSetupController < AuthenticatedController
  # The wizard's steps in order, action => title. On a first pass the step indicator is plain text
  # and the member walks it with Next; once they have finished it, each step links to its page.
  STEPS = {
    'basic_info' => 'Basic Info',
    'optional_info' => 'About You',
    'links' => 'Links',
    'interests' => 'Interests',
    'visibility' => 'Visibility'
  }.freeze

  before_action :set_user
  before_action :require_basic_info_first, except: %i[basic_info save_basic_info]
  helper_method :editing_profile?

  # Step 1: Basic Info
  def basic_info; end

  def save_basic_info
    if @user.update(basic_info_params)
      session[:profile_setup_basic_info_saved_for] = @user.id
      redirect_to profile_setup_optional_path, status: :see_other
    else
      render :basic_info, status: :unprocessable_content
    end
  end

  # Step 2: Optional Info (pronouns, bio, links)
  def optional_info
    @user_links = @user.user_links.ordered
  end

  def save_optional_info
    if @user.update(optional_info_params)
      redirect_to profile_setup_links_path, status: :see_other
    else
      @user_links = @user.user_links.ordered
      render :optional_info, status: :unprocessable_content
    end
  end

  # Step 3: Profile Links
  def links
    @user_links = @user.user_links.ordered
  end

  # Step 4: Interests
  def interests
    @user_interest_ids = @user.interests.to_set(&:id)
    @interests         = Interest.alphabetical.to_a
    @all_interests     = @interests.map { |i| { id: i.id, name: i.name } }
  end

  def add_interest
    interest = Interest.find(params[:id])
    @user.interests << interest unless @user.interests.include?(interest)
    respond_with_interest_pill(interest, selected: true)
  rescue ActiveRecord::RecordNotFound
    redirect_to profile_setup_interests_path, status: :see_other
  end

  def remove_interest
    interest = Interest.find(params[:id])
    @user.interests.delete(interest)
    respond_with_interest_pill(interest, selected: false)
  rescue ActiveRecord::RecordNotFound
    redirect_to profile_setup_interests_path, status: :see_other
  end

  def suggest_interest
    name = params[:interest_name].to_s.strip
    if name.blank?
      redirect_to profile_setup_interests_path, alert: 'Please enter an interest name.'
      return
    end

    interest = Interest.find_by('LOWER(name) = ?', name.downcase)
    interest = Interest.create!(name: name, needs_review: true, seeded: false) if interest.nil?

    @user.interests << interest unless @user.interests.include?(interest)
    notice = "'#{interest.name}' added to your profile."
    redirect_to profile_setup_interests_path, notice: notice, status: :see_other
  rescue ActiveRecord::RecordInvalid => e
    redirect_to profile_setup_interests_path, alert: "Couldn't add interest: #{e.message}", status: :see_other
  end

  # Step 5: Visibility & Greeting (with preview)
  def visibility
    load_announcers
  end

  def save_visibility
    attrs = visibility_params.to_h

    apply_greeting_option(attrs)

    attrs[:profile_setup_completed_at] = Time.current unless editing_profile?

    saved = User.transaction do
      next false unless @user.update(attrs)

      choose_announcers if @user.announce_arrivals?
      true
    end

    if saved
      session.delete(:profile_setup_basic_info_saved_for)
      redirect_to user_path(@user), notice: 'Profile setup complete!', status: :see_other
    else
      @user.restore_attributes(%i[profile_setup_completed_at])
      load_announcers
      render :visibility, status: :unprocessable_content
    end
  end

  def add_link
    @user.user_links.create!(link_params)
    redirect_to profile_setup_links_path, status: :see_other
  rescue ActiveRecord::RecordInvalid
    redirect_to profile_setup_links_path, alert: 'Please provide both a title and URL for the link.'
  end

  def remove_link
    link = @user.user_links.find(params[:link_id])
    link.destroy!
    redirect_to profile_setup_links_path, status: :see_other
  end

  private

  # Swaps the clicked interest pill in place via Turbo Stream so the page
  # (including any active search filter) is not reloaded.
  def respond_with_interest_pill(interest, selected:)
    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace(
          ActionView::RecordIdentifier.dom_id(interest, :pill),
          partial: 'profile_setup/interest_pill',
          locals: { interest: interest, selected: selected }
        )
      end
      format.html { redirect_to profile_setup_interests_path, status: :see_other }
    end
  end

  def set_user
    @user = current_user
  end

  # True once the member has finished the wizard: they are back to edit their profile, not setting it up.
  def editing_profile?
    @user.profile_setup_completed_at.present?
  end

  # On a first pass the later steps are only reachable once Basic Info has been saved, so their URLs
  # can't be used to skip it. The mark lives in the session, for the member it was saved for.
  def require_basic_info_first
    return if editing_profile? || session[:profile_setup_basic_info_saved_for] == @user.id

    redirect_to profile_setup_path, alert: 'Start with your basic info.', status: :see_other
  end

  # Turns the greeting radio buttons into the user's greeting columns.
  def apply_greeting_option(attrs)
    case params.dig(:user, :greeting_option)
    when 'full_name'
      attrs[:use_full_name_for_greeting] = true
      attrs[:use_username_for_greeting]  = false
      attrs[:do_not_greet]               = false
    when 'username'
      attrs[:use_full_name_for_greeting] = false
      attrs[:use_username_for_greeting]  = true
      attrs[:do_not_greet]               = false
    when 'custom'
      attrs[:use_full_name_for_greeting] = false
      attrs[:use_username_for_greeting]  = false
      attrs[:do_not_greet]               = false
      attrs[:greeting_name]              = params.dig(:user, :greeting_name).to_s.strip
    when 'do_not_greet'
      attrs[:use_full_name_for_greeting] = false
      attrs[:use_username_for_greeting]  = false
      attrs[:do_not_greet]               = true
      attrs[:greeting_name]              = ''
    end
  end

  def basic_info_params
    params.expect(user: %i[full_name email username])
  end

  def visibility_params
    params.expect(user: %i[profile_visibility greeting_name announce_arrivals])
  end

  def load_announcers
    @announcers = Announcer.enabled.ordered
  end

  # Only the announcers a member can see are changed: a choice of one that is currently disabled
  # is kept for when it comes back. While announce_arrivals is off the checkboxes are hidden and
  # ignored, so switching it off and on again keeps what the member picked.
  def choose_announcers
    chosen = Announcer.enabled.where(id: Array(params.dig(:user, :announcer_ids))).pluck(:id)
    @user.announcer_subscriptions.where(announcer_id: Announcer.enabled.select(:id))
         .where.not(announcer_id: chosen).destroy_all
    (chosen - @user.announcer_subscriptions.pluck(:announcer_id)).each do |id|
      @user.announcer_subscriptions.create!(announcer_id: id)
    end
  end

  def optional_info_params
    params.expect(user: %i[pronouns bio])
  end

  def link_params
    params.expect(user_link: %i[title url])
  end
end
