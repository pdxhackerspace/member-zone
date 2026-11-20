class TrainingTopicLink < ApplicationRecord
  belongs_to :training_topic
  has_one :content_snapshot, class_name: 'TrainingTopicLinkSnapshot', dependent: :destroy,
                             inverse_of: :training_topic_link

  validates :title, presence: true
  validates :url, presence: true, format: { with: URI::DEFAULT_PARSER.make_regexp(%w[http https]), message: 'must be a valid URL' }

  after_create_commit :log_training_link_added
  after_update_commit :log_training_link_updated
  after_destroy_commit :log_training_link_removed

  private

  def log_training_link_added
    TrainingResources::ChangeLog.link_added(self)
  end

  def log_training_link_updated
    TrainingResources::ChangeLog.link_updated(self)
    content_snapshot&.destroy if saved_change_to_url?
  end

  def log_training_link_removed
    TrainingResources::ChangeLog.link_removed(self)
  end
end
