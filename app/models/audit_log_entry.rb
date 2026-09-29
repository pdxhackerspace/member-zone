# One line of an audit log. Entries are append-only: nothing deletes them and only the
# explanation and alert bookkeeping can change once a row exists. The guarantee is enforced
# here, in the application; the foreign key from the source blocks the one cascade that
# could otherwise remove entries.
class AuditLogEntry < ApplicationRecord
  class Immutable < StandardError; end

  # Columns that may change after insert.
  MUTABLE_ATTRIBUTES = %w[explanation explained_by_id explained_at matched_rule_ids alerted_at updated_at].freeze

  # Removal entry points on a relation. Prepended onto every relation class the model has, so
  # `AuditLogEntry.where(...).delete_all` is refused the same way `entry.destroy` is.
  module RefuseRemoval
    def delete_all(*)
      raise Immutable, 'audit log entries cannot be deleted'
    end

    def destroy_all(*)
      raise Immutable, 'audit log entries cannot be deleted'
    end

    def delete_by(*)
      raise Immutable, 'audit log entries cannot be deleted'
    end

    def destroy_by(*)
      raise Immutable, 'audit log entries cannot be deleted'
    end
  end

  belongs_to :audit_log_source
  belongs_to :explained_by, class_name: 'User', optional: true

  validates :occurred_at, :message, :fingerprint, presence: true
  validates :fingerprint, uniqueness: { scope: :audit_log_source_id }
  validate :only_annotations_change, on: :update

  before_destroy { throw :abort }

  scope :newest_first, -> { order(occurred_at: :desc, id: :desc) }
  scope :unexplained, -> { where(explanation: [nil, '']) }
  scope :alerted, -> { where.not(alerted_at: nil) }
  scope :matching, ->(term) { where('audit_log_entries.message ILIKE ?', "%#{sanitize_sql_like(term)}%") }

  [ActiveRecord::Relation, ActiveRecord::AssociationRelation,
   ActiveRecord::Associations::CollectionProxy].each do |base|
    relation_delegate_class(base).prepend(RefuseRemoval)
  end

  def self.delete(*)
    raise Immutable, 'audit log entries cannot be deleted'
  end

  def self.delete_all(*)
    raise Immutable, 'audit log entries cannot be deleted'
  end

  def self.destroy_all(*)
    raise Immutable, 'audit log entries cannot be deleted'
  end

  def delete
    raise Immutable, 'audit log entries cannot be deleted'
  end

  def explained?
    explanation.present?
  end

  def alerted?
    alerted_at.present?
  end

  # Records who wrote the explanation. Clearing it clears the attribution too. Replacing or
  # clearing an explanation that was already there is journaled with the old and new text,
  # because the entry itself keeps only the latest.
  def explain!(text, by:)
    text = text.to_s.strip.presence
    previous = explanation.presence
    return if text == previous

    transaction do
      update!(explanation: text, explained_by: (by if text), explained_at: (Time.current if text))
      journal_rewrite!(previous, text, by) if previous
    end
  end

  private

  def journal_rewrite!(from, to, actor)
    Journal.create!(
      user: nil, actor_user: actor, action: 'audit_log_explanation_rewritten', highlight: true,
      changed_at: Time.current,
      changes_json: { 'audit_log_entry' => { 'id' => id, 'source' => audit_log_source.name,
                                             'message' => message.truncate(200),
                                             'explanation' => { 'from' => from, 'to' => to } } }
    )
  end

  def only_annotations_change
    locked = changed - MUTABLE_ATTRIBUTES
    return if locked.empty?

    errors.add(:base, "audit log entries cannot be edited (#{locked.join(', ')})")
  end
end
