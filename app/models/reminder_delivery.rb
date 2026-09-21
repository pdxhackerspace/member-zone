# How far through its reminder sequence one subject is: how many have gone out, when the last
# one did, and which anchor the sequence is counting from.
#
# The anchor matters because reminders restart. A member who pays up and falls behind again is
# at reminder one, not at whatever count they reached the last time round, and the anchor
# moving is how we know. See Reminders::Schedule for the cadence itself.
class ReminderDelivery < ApplicationRecord
  # Anchors are frequently computed rather than read off a column, so an anchor that differs
  # by less than this is the same anchor rounded differently, not a restarted sequence.
  ANCHOR_DRIFT_TOLERANCE = 1.second

  belongs_to :subject, polymorphic: true

  validates :reminder_key, presence: true
  validates :subject_type, presence: true
  validates :sent_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :for_reminder, ->(key) { where(reminder_key: key) }

  def self.state_for(reminder_key, subject)
    return nil if subject.blank? || subject.id.blank?

    find_by(reminder_key: reminder_key, subject_type: subject.class.polymorphic_name, subject_id: subject.id)
  end

  # Progress for a page of subjects, keyed by subject id, in one query rather than per row.
  def self.index_for(reminder_key, subjects)
    subjects = Array(subjects)
    return {} if subjects.empty?

    where(reminder_key: reminder_key,
          subject_type: subjects.first.class.polymorphic_name,
          subject_id: subjects.map(&:id)).index_by(&:subject_id)
  end

  # Counts one reminder as sent. Called after the mail has actually left, not when it is
  # queued — mail held for review has not reached anyone, so it must not move the clock.
  def self.record!(reminder_key, subject, anchor: nil, at: Time.current)
    delivery = create_or_find_by!(
      reminder_key: reminder_key,
      subject_type: subject.class.polymorphic_name,
      subject_id: subject.id
    )
    delivery.with_lock { delivery.record_send!(anchor: anchor, at: at) }
    delivery
  end

  def record_send!(anchor: nil, at: Time.current)
    if restarted_by?(anchor)
      update!(anchor_at: anchor, sent_count: 1, first_sent_at: at, last_sent_at: at)
    else
      update!(anchor_at: anchor_at || anchor, sent_count: sent_count + 1,
              first_sent_at: first_sent_at || at, last_sent_at: at)
    end
  end

  # A backfilled row has no anchor recorded, so the first send after the upgrade adopts
  # whatever anchor it is given rather than reading as a restart and throwing the count away.
  def restarted_by?(anchor)
    return false if anchor.blank? || anchor_at.blank?

    (anchor - anchor_at).abs > ANCHOR_DRIFT_TOLERANCE
  end
end
