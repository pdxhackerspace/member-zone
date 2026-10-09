# Permits issued by an access control device. A "blank" permit is issued before anybody has said
# what was parked or where; it is waiting for details until it has a description and location.
module ParkingNoticeDeviceDetails
  extend ActiveSupport::Concern

  included do
    belongs_to :webhook_device, optional: true
    has_many :parking_permit_links, dependent: :delete_all

    before_save :mark_details_completed, if: :awaiting_details?

    scope :awaiting_details, -> { where.not(details_requested_at: nil).where(details_completed_at: nil) }
  end

  def awaiting_details?
    details_requested_at.present? && details_completed_at.blank?
  end

  def details_present?
    description.present? && location.present?
  end

  private

  # However the details arrive — the no-login link, a member's own edit page, an admin — a blank
  # permit stops being blank once it says what was parked and where, and its reminders stop.
  def mark_details_completed
    self.details_completed_at = Time.current if details_present?
  end
end
