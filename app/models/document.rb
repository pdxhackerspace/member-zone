class Document < ApplicationRecord
  has_one_attached :file
  has_many :document_training_topics, dependent: :destroy
  has_many :training_topics, through: :document_training_topics,
                             after_add: :log_topic_document_added,
                             after_remove: :log_topic_document_removed

  validates :title, presence: true
  validates :file, presence: true

  scope :ordered, -> { order(:title) }

  before_save :capture_training_resource_edit
  before_destroy :remember_topics_for_change_log, prepend: true
  after_create_commit :log_topics_added_with_document
  after_update_commit :log_training_resource_edit
  after_destroy_commit :log_training_resource_removal

  def filename
    file.filename.to_s if file.attached?
  end

  private

  def capture_training_resource_edit
    @training_resource_edit = nil
    return if new_record?

    title = will_save_change_to_title? ? title_change_to_be_saved : nil
    file_change = replacement_file
    return if title.nil? && file_change.nil?

    @training_resource_edit = { title: title, file: file_change }.compact
  end

  # file.blob already points at the replacement while the change is pending, so the
  # previous file is the attachment still stored for this document.
  def replacement_file
    change = attachment_changes['file']
    return unless change.is_a?(ActiveStorage::Attached::Changes::CreateOne)

    previous = ActiveStorage::Attachment.find_by(record: self, name: 'file')&.blob
    return if previous&.id.present? && previous.id == change.blob.id

    { 'from' => previous && blob_snapshot(previous), 'to' => blob_snapshot(change.blob) }
  end

  def blob_snapshot(blob)
    { 'filename' => blob.filename.to_s, 'byte_size' => blob.byte_size }
  end

  def log_training_resource_edit
    return if @training_resource_edit.blank?

    training_topics.find_each do |topic|
      TrainingResources::ChangeLog.document_updated(self, topic, @training_resource_edit)
    end
  end

  # after_add runs when ids are assigned, including on the unsaved record the new
  # form builds. Those topics are logged once the document actually exists.
  def log_topic_document_added(topic)
    return if new_record?

    TrainingResources::ChangeLog.document_added(self, topic)
  end

  def log_topics_added_with_document
    training_topics.each { |topic| TrainingResources::ChangeLog.document_added(self, topic) }
  end

  def log_topic_document_removed(topic)
    return if @topics_for_change_log

    TrainingResources::ChangeLog.document_removed(self, topic)
  end

  # The join rows are destroyed by dependent: :destroy before a normal before_destroy,
  # and a document loaded by id has not cached its topics. Read them first.
  def remember_topics_for_change_log
    @topics_for_change_log = training_topics.to_a
  end

  def log_training_resource_removal
    Array(@topics_for_change_log).each do |topic|
      TrainingResources::ChangeLog.document_removed(self, topic)
    end
  end
end
