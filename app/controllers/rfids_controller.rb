class RfidsController < AuthenticatedController
  before_action -> { require_privilege!(:'access.manage_rfids') }
  before_action :set_rfid, only: %i[destroy sync_prompt]

  def new
    @rfid = Rfid.new(user_id: params.dig(:rfid, :user_id), rfid: DefaultSetting.instance.rfid_facility_prefix)
    prepare_form_data
  end

  def create
    @rfid = Rfid.new(rfid_params)
    existing = Rfid.find_by(rfid: @rfid.rfid)

    if existing && existing.user_id != @rfid.user_id && params[:confirm_reassign] != '1'
      @existing_rfid = existing
      @existing_owner = existing.user
      prepare_form_data
      flash.now[:warning] = 'This RFID code is already assigned to another member.'
      render :new, status: :unprocessable_content
      return
    end

    Rfid.transaction do
      if existing && existing.user_id != @rfid.user_id
        @reassigned_from = existing.user
        existing.destroy!
      end

      if @rfid.save
        training_added = false
        training_added = add_building_access_training(@rfid.user) if params[:add_training] == '1'
        notice = "Key fob added successfully for #{@rfid.user.display_name}."
        notice += " Reassigned from #{@reassigned_from.display_name}." if @reassigned_from
        notice += ' Building Access training also recorded.' if training_added
        redirect_to sync_prompt_rfid_path(@rfid), notice: notice
      else
        prepare_form_data
        flash.now[:alert] = 'Unable to add key fob.'
        render :new, status: :unprocessable_content
      end
    end
  end

  def destroy
    user = @rfid.user
    @rfid.destroy!
    redirect_to user_path(user), notice: 'Key fob removed.'
  end

  # After adding a fob: warn that doors need a controller sync before the key works.
  def sync_prompt
    @user = @rfid.user
    @enabled_controllers_count = AccessController.enabled.count
  end

  private

  def set_rfid
    @rfid = Rfid.find(params[:id])
  end

  def rfid_params
    params.expect(rfid: %i[user_id rfid notes])
  end

  def prepare_form_data
    @users = User.ordered_by_display_name
    @building_access_topic = TrainingTopic.building_access
    @trained_user_ids = if @building_access_topic
                          Training.where(training_topic: @building_access_topic).pluck(:trainee_id).to_set
                        else
                          Set.new
                        end
  end

  def add_building_access_training(user)
    topic = TrainingTopic.building_access
    return false unless topic
    return false if Training.exists?(trainee: user, training_topic: topic)
    # Recording training here would confer the topic's roles, so the same no-escalation rule
    # applies as in the training controller.
    return false unless current_user.may_confer?(topic, member_sources: %w[trained_in])

    training = Training.create!(
      trainee: user,
      trainer: true_user,
      training_topic: topic,
      trained_at: Time.current
    )

    Journal.create!(
      user: user,
      actor_user: true_user,
      action: 'training_added',
      changes_json: {
        'training' => {
          'topic' => topic.name,
          'trainer' => true_user.display_name,
          'trained_at' => training.trained_at.iso8601
        }
      },
      changed_at: Time.current,
      highlight: true
    )
    true
  end
end
