# A member's choice to be announced by one announcer. Only counts while the member also has
# User#announce_arrivals switched on, so turning that off pauses every announcer without
# forgetting which ones they picked.
class AnnouncerSubscription < ApplicationRecord
  belongs_to :announcer
  belongs_to :user

  validates :announcer_id, uniqueness: { scope: :user_id }
end
