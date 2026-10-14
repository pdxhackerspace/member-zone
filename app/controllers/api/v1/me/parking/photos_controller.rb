module Api
  module V1
    module Me
      module Parking
        # Photos on the token holder's own notices. Anyone on a notice may see its photos; only
        # permits, which members manage themselves, take new ones or lose old ones.
        class PhotosController < BaseController
          # OwnParkingNotices first: its scope and token checks must run before any record lookup.
          include OwnParkingNotices
          include ParkingNoticePhotos

          private

          def changeable_notice!
            require_permit
            performed?
          end
        end
      end
    end
  end
end
