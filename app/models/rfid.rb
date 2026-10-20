class Rfid < ApplicationRecord
  belongs_to :user

  validates :rfid, presence: true, uniqueness: { scope: :user_id }

  def rfid=(value)
    super(RfidNormalizer.call(value))
  end

  after_create_commit :journal_key_fob_added!
  after_destroy_commit :journal_key_fob_removed!
  after_destroy_commit :enqueue_access_controller_member_keys_sync!

  private

  def enqueue_access_controller_member_keys_sync!
    AccessControllerMemberKeysSyncJob.perform_later(Current.actor&.id)
  end

  def journal_key_fob_added!
    record_key_fob_journal!('key_fob_added')
  end

  def journal_key_fob_removed!
    return if destroyed_by_association.present?

    record_key_fob_journal!('key_fob_removed')
  end

  def record_key_fob_journal!(action)
    Journal.create!(
      user: user,
      actor_user: Current.actor,
      action: action,
      changes_json: {
        'key_fob' => {
          'rfid' => rfid,
          'notes' => notes
        }
      },
      changed_at: Time.current,
      highlight: true
    )
  end
end
