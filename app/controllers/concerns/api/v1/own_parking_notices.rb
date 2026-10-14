module Api
  module V1
    # The token holder's own parking notices: parking.own_permits on a personal token.
    module OwnParkingNotices
      extend ActiveSupport::Concern

      included do
        before_action -> { require_scope!(:'parking.own_permits') }
        before_action :require_personal_token
      end

      private

      def notice_scope
        ParkingNotice.for_user(current_user)
      end

      def photo_download_path(photo)
        api_v1_me_parking_notice_photo_path(photo.record_id, photo.id)
      end

      def require_personal_token
        return if personal_token?

        render_error(:forbidden, 'Only a personal token has parking notices of its own. Service accounts act for ' \
                                 'members through /parking/notices.', status: :forbidden)
      end

      # Tickets are issued by staff; members may view and clear them but not change them.
      def require_permit
        return if @notice.permit?

        render_error(:forbidden, 'Parking ticket details are managed by staff.', status: :forbidden)
      end
    end
  end
end
