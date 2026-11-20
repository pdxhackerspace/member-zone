class TrainingResourceChange < ApplicationRecord
  KINDS = %w[
    link_added link_updated link_removed link_content_changed
    document_added document_updated document_removed
  ].freeze

  KIND_LABELS = {
    'link_added' => 'Link added',
    'link_updated' => 'Link updated',
    'link_removed' => 'Link removed',
    'link_content_changed' => 'Link content changed',
    'document_added' => 'Document added',
    'document_updated' => 'Document updated',
    'document_removed' => 'Document removed'
  }.freeze

  belongs_to :training_topic
  belongs_to :actor, class_name: 'User', optional: true

  validates :kind, inclusion: { in: KINDS }
  validates :title, presence: true
  validates :occurred_at, presence: true

  scope :pending, -> { where(notified_at: nil) }

  def kind_label
    KIND_LABELS.fetch(kind, kind.humanize)
  end
end
