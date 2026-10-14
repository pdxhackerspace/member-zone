class ParkingNoticeEvent < ApplicationRecord
  EVENT_TYPES = %w[opened renewed cleared expired clearance_requested note].freeze

  belongs_to :parking_notice
  belongs_to :actor, class_name: 'User', optional: true
  # Set when the change came in through the API, so the history says so.
  belongs_to :api_token, optional: true

  before_create { self.api_token ||= Current.api_token }

  validates :event_type, presence: true, inclusion: { in: EVENT_TYPES }
  validates :note, presence: true, if: -> { event_type == 'note' }

  scope :chronological, -> { order(created_at: :asc, id: :asc) }
  scope :recent_first, -> { order(created_at: :desc, id: :desc) }

  def label
    case event_type
    when 'opened' then 'Opened'
    when 'renewed' then 'Renewed'
    when 'cleared' then 'Cleared'
    when 'expired' then 'Expired'
    when 'clearance_requested' then 'Clearance requested'
    when 'note' then 'Note'
    else event_type.humanize
    end
  end

  def icon
    case event_type
    when 'opened' then 'bi-plus-circle'
    when 'renewed' then 'bi-arrow-repeat'
    when 'cleared' then 'bi-check-circle'
    when 'expired' then 'bi-clock-history'
    when 'clearance_requested' then 'bi-hand-index'
    when 'note' then 'bi-chat-left-text'
    else 'bi-dot'
    end
  end
end
