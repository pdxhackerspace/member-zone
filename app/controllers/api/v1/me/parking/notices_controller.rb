module Api
  module V1
    module Me
      module Parking
        # The token holder's own parking permits and tickets, under parking.own_permits — what a
        # member can do for themselves on the website. Personal tokens only: a service account has
        # no parking notices of its own, and acts for members through /parking/notices instead.
        class NoticesController < BaseController
          # OwnParkingNotices first: its scope and token checks must run before any record lookup.
          include OwnParkingNotices
          include ParkingNoticeEndpoints

          ATTRIBUTES = %i[description location location_detail expires_at].freeze

          # As on the website, members change and print their permits; tickets are staff's.
          before_action :require_permit, if: -> { action_name.in?(%w[update pdf print]) }

          # Always a permit, at most two weeks long, with the holder on it.
          def create
            result = ParkingNotices::Issue.call(actor: current_user, attributes: notice_attributes(*ATTRIBUTES),
                                                member_ids: Array(params[:member_ids]), self_service: true)
            render_result(result, status: :created)
          end

          def update
            result = ParkingNotices::Update.call(notice: @notice, actor: current_user,
                                                 attributes: notice_attributes(*ATTRIBUTES),
                                                 member_ids: requested_member_ids, self_service: true)
            render_result(result)
          end

          def close
            render_result(ParkingNotices::Clear.call(notice: @notice, actor: current_user))
          end

          def request_clearance
            render_result(ParkingNotices::RequestClearance.call(notice: @notice, actor: current_user))
          end
        end
      end
    end
  end
end
