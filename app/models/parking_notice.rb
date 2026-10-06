class ParkingNotice < ApplicationRecord
  NOTICE_TYPES = %w[permit ticket].freeze
  STATUSES = %w[active expired cleared].freeze

  belongs_to :issued_by, class_name: 'User'
  belongs_to :cleared_by, class_name: 'User', optional: true
  belongs_to :clearance_requested_by, class_name: 'User', optional: true

  has_many :parking_notice_members, dependent: :destroy
  has_many :members, through: :parking_notice_members, source: :user
  has_many :events, class_name: 'ParkingNoticeEvent', dependent: :destroy
  has_many_attached :photos

  # Set by controllers so history events can record who triggered the change.
  attr_accessor :event_actor

  validates :notice_type, presence: true, inclusion: { in: NOTICE_TYPES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :expires_at, presence: true
  validate :members_present_for_permit

  after_create :log_opened_event
  after_update :log_renewal_event, if: :renewal_logged?

  scope :permits, -> { where(notice_type: 'permit') }
  scope :tickets, -> { where(notice_type: 'ticket') }
  scope :active_notices, -> { where(status: 'active') }
  scope :expired_notices, -> { where(status: 'expired') }
  scope :cleared_notices, -> { where(status: 'cleared') }
  scope :not_cleared, -> { where.not(status: 'cleared') }
  scope :needing_expiration, -> { active_notices.where(expires_at: ..Time.current) }
  scope :remindable, -> { not_cleared.where(status: %w[active expired]) }
  scope :ordered, -> { order(expires_at: :asc) }
  scope :newest_first, -> { order(created_at: :desc) }
  scope :for_user, lambda { |user|
    joins(:parking_notice_members).where(parking_notice_members: { user_id: user }).distinct
  }

  def permit?
    notice_type == 'permit'
  end

  def ticket?
    notice_type == 'ticket'
  end

  def active?
    status == 'active'
  end

  def expired?
    status == 'expired'
  end

  def cleared?
    status == 'cleared'
  end

  def past_expiration?
    expires_at <= Time.current
  end

  def notice_type_display
    notice_type&.capitalize
  end

  def status_display
    status&.capitalize
  end

  def badge_color
    permit? ? 'success' : 'danger'
  end

  def status_badge_color
    case status
    when 'active' then 'primary'
    when 'expired' then 'danger'
    else 'secondary' # cleared and unknown statuses
    end
  end

  def location_display
    parts = []
    parts << location if location.present?
    parts << location_detail if location_detail.present?
    parts.join(' — ')
  end

  def member?(user)
    return false if user.blank?

    if members.loaded?
      members.any? { |member| member.id == user.id }
    else
      parking_notice_members.exists?(user_id: user.id)
    end
  end

  def members_label
    members.map(&:parking_member_label).join(', ')
  end

  # Replaces the member list. Returns User records that were newly added.
  def replace_members!(member_ids)
    ids = Array(member_ids).filter_map { |raw| raw.presence&.to_i }.uniq
    if permit? && ids.empty?
      errors.add(:members, 'must include at least one member')
      raise ActiveRecord::RecordInvalid, self
    end

    previous_ids = members.pluck(:id)

    transaction do
      parking_notice_members.where.not(user_id: ids).destroy_all
      ids.each do |user_id|
        parking_notice_members.find_or_create_by!(user_id: user_id)
      end
    end

    members.reload
    members.select { |member| ids.include?(member.id) && previous_ids.exclude?(member.id) }
  end

  def build_members_from_ids!(member_ids)
    ids = Array(member_ids).filter_map { |raw| raw.presence&.to_i }.uniq
    if persisted?
      replace_members!(ids)
    else
      self.members = User.where(id: ids).to_a
    end
  end

  def notify_issued!(recipients = members)
    Array(recipients).filter_map do |member|
      enqueue_notification!(issued_template_key, recipient: member)
    end
  end

  # A member may clear their own active or expired notice unless it has been
  # flagged as requiring admin clearance. Admins can always clear any
  # uncleared notice.
  def clearable_by?(actor)
    return false if cleared? || actor.blank?
    return true if actor.admin? || actor.can?(:'parking.clear_admin_required')
    return false if requires_admin_clearance?
    return true if actor.can?(:'parking.manage_notices')

    member?(actor)
  end

  def clearance_requested?
    clearance_requested_at.present? && !cleared?
  end

  def clear!(actor)
    transaction do
      update!(
        status: 'cleared',
        cleared_at: Time.current,
        cleared_by: actor
      )
      log_event!('cleared', actor: actor)
    end
  end

  def expire!
    transaction do
      update!(status: 'expired')
      log_event!('expired')
    end
  end

  def request_clearance!(member)
    transaction do
      update!(clearance_requested_at: Time.current, clearance_requested_by: member)
      log_event!('clearance_requested', actor: member)
    end
  end

  def log_event!(event_type, actor: nil, note: nil)
    events.create!(event_type: event_type, actor: actor, note: note.presence)
  end

  def record_journal_entry!(action_name, actor: nil)
    members.find_each do |member|
      Journal.create!(
        user: member,
        actor_user: actor,
        action: action_name,
        changes_json: journal_payload,
        changed_at: Time.current,
        highlight: true
      )
    end
  end

  def enqueue_notification!(template_key, recipient: nil)
    targets = recipient.present? ? [recipient] : deliverable_members
    results = targets.filter_map { |member| enqueue_notification_to!(template_key, member) }
    return results.first if recipient.present?

    results
  end

  def deliverable_members
    members.select { |member| member_deliverable?(member) }
  end

  def template_key_for_reminder_phase(phase)
    case phase
    when :pre_expiration then expiring_soon_template_key
    when :expiration then expired_template_key
    when :overdue then overdue_reminder_template_key
    when :final then final_reminder_template_key
    end
  end

  def expiring_soon_template_key
    permit? ? 'parking_permit_expiring_soon' : 'parking_ticket_expiring_soon'
  end

  def expired_template_key
    permit? ? 'parking_permit_expired' : 'parking_ticket_expired'
  end

  def overdue_reminder_template_key
    permit? ? 'parking_permit_overdue_reminder' : 'parking_ticket_overdue_reminder'
  end

  def final_reminder_template_key
    permit? ? 'parking_permit_final_reminder' : 'parking_ticket_final_reminder'
  end

  def issued_template_key
    permit? ? 'parking_permit_issued' : 'parking_ticket_issued'
  end

  private

  def members_present_for_permit
    return unless permit?

    count = parking_notice_members.reject(&:marked_for_destruction?).size
    return if count.positive?

    errors.add(:members, 'must include at least one member')
  end

  def journal_payload
    {
      'parking_notice' => {
        'id' => id,
        'notice_type' => notice_type,
        'location' => location_display,
        'expires_at' => expires_at.strftime('%B %d, %Y'),
        'description' => description.to_s.truncate(100)
      }
    }
  end

  def enqueue_notification_to!(template_key, user)
    return if user.blank? || user.email.blank?

    QueuedMail.enqueue(
      template_key,
      user,
      reason: "Parking #{notice_type}: #{template_key.humanize}",
      location: location_display,
      location_detail: location_detail.to_s,
      description: description.to_s,
      expires_at: expires_at.strftime('%B %d, %Y'),
      notice_type: notice_type_display,
      parking_notice_id: id
    )
  end

  def member_deliverable?(member)
    return false if member.blank? || member.email.blank?
    return false if MailRecipientGuard.blocked?(member)
    return false if MembershipState::TERMINAL_STATES.include?(member.membership_state)

    category = NotificationCategory.reminder_backed.find { |entry| entry.reminder_key == 'parking_notices' }&.key
    return true unless category && NotificationCategory.opt_out_allowed?(category)

    !NotificationOptOut.opted_out?(member, category: category, channel: 'email')
  end

  def log_opened_event
    log_event!('opened', actor: event_actor || issued_by)
  end

  def log_renewal_event
    log_event!('renewed', actor: event_actor)
  end

  def renewal_logged?
    saved_change_to_expires_at? && !saved_change_to_status?
  end
end
