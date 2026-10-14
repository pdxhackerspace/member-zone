module Api
  module V1
    module Parking
      # Staff access to every parking permit and ticket, under parking.manage_notices. Members are
      # named explicitly by id, since the token is not acting for any one of them.
      class NoticesController < BaseController
        # Ahead of the concern's record lookup, so a token without the scope learns nothing about
        # which notices exist.
        before_action -> { require_scope!(:'parking.manage_notices') }

        include ParkingNoticeEndpoints

        ATTRIBUTES = %i[notice_type description location location_detail expires_at requires_admin_clearance].freeze

        def create
          result = ParkingNotices::Issue.call(actor: current_user, attributes: notice_attributes(*ATTRIBUTES),
                                              member_ids: Array(params[:member_ids]))
          render_result(result, status: :created)
        end

        def update
          result = ParkingNotices::Update.call(notice: @notice, actor: current_user,
                                               attributes: notice_attributes(*ATTRIBUTES),
                                               member_ids: requested_member_ids)
          render_result(result)
        end

        def clear
          render_result(ParkingNotices::Clear.call(notice: @notice, actor: current_user))
        end

        private

        def notice_scope
          ParkingNotice.all
        end

        def filtered(notices)
          scoped = super
          return scoped if params[:member_id].blank?

          scoped.for_user(User.find(params[:member_id]))
        end

        def photo_download_path(photo)
          api_v1_parking_notice_photo_path(photo.record_id, photo.id)
        end
      end
    end
  end
end
