# Defines a type/class of access controller with a shared script and configuration.
# Can optionally require users to be trained in specific topics before being synced.
class AccessControllerType < ApplicationRecord
  has_many :access_controllers, dependent: :restrict_with_error
  has_many :access_controller_type_training_topics, dependent: :destroy
  has_many :required_training_topics, through: :access_controller_type_training_topics, source: :training_topic

  validates :name, presence: true, uniqueness: true
  validates :script_path, presence: true
  validates :enabled, inclusion: { in: [true, false] }
  validate :script_path_in_catalog, if: :will_save_change_to_script_path?

  scope :enabled, -> { where(enabled: true) }
  scope :ordered, -> { order(:name) }

  # Returns true if the user has completed all required training topics for this type.
  # If no topics are required, all users qualify.
  def user_meets_training_requirements?(user)
    required_ids = required_training_topic_ids
    return true if required_ids.empty?

    trained_ids = user.trainings_as_trainee.pluck(:training_topic_id).uniq
    (required_ids - trained_ids).empty?
  end

  private

  def script_path_in_catalog
    return if script_path.blank?
    return if AccessControllers::ScriptCatalog.allowed?(script_path)

    errors.add(:script_path, 'must be an executable file in an access script directory')
  end
end
