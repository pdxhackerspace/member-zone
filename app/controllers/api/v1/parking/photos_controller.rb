module Api
  module V1
    module Parking
      # Photos on any parking notice, under parking.manage_notices.
      class PhotosController < BaseController
        # Ahead of the concern's record lookups, so a token without the scope learns nothing.
        before_action -> { require_scope!(:'parking.manage_notices') }

        include ParkingNoticePhotos

        private

        def notice_scope
          ParkingNotice.all
        end

        def photo_download_path(photo)
          api_v1_parking_notice_photo_path(photo.record_id, photo.id)
        end
      end
    end
  end
end
