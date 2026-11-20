class ParkingNoticeMember < ApplicationRecord
  # How long a clear link in an arrival reminder keeps working. Opening the link does not
  # clear the notice; the page it opens does, so a mail scanner following the URL is harmless.
  ARRIVAL_CLEARANCE_TTL = 7.days

  belongs_to :parking_notice
  belongs_to :user

  validates :user_id, uniqueness: { scope: :parking_notice_id }

  generates_token_for :arrival_clearance, expires_in: ARRIVAL_CLEARANCE_TTL do
    "#{parking_notice_id}:#{user_id}"
  end
end
