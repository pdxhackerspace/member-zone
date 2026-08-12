# Building access training is the orientation that lets a member into the space. Recording
# it moves a new member on to provisional_member, so "has had it" and "is still waiting for
# it" are questions the orientation reminder and several reports all need to ask.
module BuildingAccessTraining
  extend ActiveSupport::Concern

  TRAINING_EXISTS_SQL = 'SELECT 1 FROM trainings WHERE trainings.trainee_id = users.id ' \
                        'AND trainings.training_topic_id = ?'.freeze

  included do
    # Both scopes narrow only when a building access topic is configured. With none set
    # there is nothing to have been trained on, and filtering either way would quietly
    # empty the caller's list instead of saying the topic is missing.
    scope :building_access_trained, -> { building_access_training_filter('EXISTS') }
    scope :awaiting_building_access_training, -> { building_access_training_filter('NOT EXISTS') }
  end

  class_methods do
    def building_access_training_filter(operator)
      topic = TrainingTopic.building_access
      return all if topic.nil?

      where("#{operator} (#{TRAINING_EXISTS_SQL})", topic.id)
    end
  end

  def building_access_trained?
    topic = TrainingTopic.building_access
    return false if topic.nil?

    Training.exists?(trainee_id: id, training_topic_id: topic.id)
  end
end
