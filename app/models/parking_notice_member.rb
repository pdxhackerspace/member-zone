class ParkingNoticeMember < ApplicationRecord
  belongs_to :parking_notice
  belongs_to :user

  validates :user_id, uniqueness: { scope: :parking_notice_id }
end
