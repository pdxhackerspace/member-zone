module TrainerCapabilityActions
  extend ActiveSupport::Concern

  def add_trainer_capability
    unless can_manage_trainer_capability?(@training_topic)
      redirect_to record_training_path, alert: 'You do not have permission to manage trainer capabilities.'
      return
    end

    existing = TrainerCapability.find_by(user: @trainee, training_topic: @training_topic)
    if existing
      redirect_to trainer_capability_return_path(@trainee),
                  notice: "#{@trainee.display_name} can already train #{@training_topic.name}."
      return
    end

    if @trainee.banned?
      redirect_to trainer_capability_return_path(@trainee),
                  alert: "#{@trainee.display_name} is banned and cannot be made a trainer."
      return
    end

    TrainerAppointer.new(current_user: true_user, training_topic: @training_topic, trainee_ids: [@trainee.id],
                         trainer: true_user, trained_at: Time.current, notify_inactive: true).call
    redirect_to trainer_capability_return_path(@trainee),
                notice: "#{@trainee.display_name} can now train others in #{@training_topic.name}."
  end

  def remove_trainer_capability
    unless can_manage_trainer_capability?(@training_topic)
      redirect_to record_training_path, alert: 'You do not have permission to manage trainer capabilities.'
      return
    end

    capability = TrainerCapability.find_by(user: @trainee, training_topic: @training_topic)

    if capability&.destroy
      log_trainer_capability_removed
      redirect_to trainer_capability_return_path(@trainee),
                  notice: "Removed #{@training_topic.name} trainer capability from #{@trainee.display_name}."
    else
      redirect_to trainer_capability_return_path(@trainee),
                  alert: "#{@trainee.display_name} did not have trainer capability for #{@training_topic.name}."
    end
  end

  private

  # Resolved against the real signed-in account, like every other privilege check: an
  # impersonated session must not be able to appoint trainers on the target's authority.
  def can_manage_trainer_capability?(topic)
    current_user&.may_manage_trainer_capability?(topic) || false
  end

  def log_trainer_capability_removed
    Journal.create!(
      user: @trainee,
      actor_user: true_user,
      action: 'trainer_capability_removed',
      changes_json: {
        'trainer_capability' => {
          'topic' => @training_topic.name,
          'revoked_by' => true_user.display_name,
          'revoked_at' => Time.current.iso8601
        }
      },
      changed_at: Time.current,
      highlight: true
    )
  end

  def trainer_capability_return_path(trainee)
    user_path(trainee, anchor: 'training-access-section')
  end
end
