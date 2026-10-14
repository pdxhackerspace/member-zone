module Api
  module V1
    # Finds members by name, username, alias, or full email address — the API form of the member
    # picker, under the same api.users.search grant. Profiles hidden from the holder stay hidden
    # unless the token also carries members.view_profile.
    class MembersController < BaseController
      before_action -> { require_scope!(:'api.users.search') }

      def index
        query = params[:q].to_s.strip
        return render_error(:bad_request, 'q is required.', status: :bad_request) if query.blank?

        members = members_visible_to_viewer(User.search_for_picker(query))
                  .non_service_accounts.ordered_by_display_name.limit(20)
        render json: { data: members.map { |member| MemberSerializer.call(member) } }
      end

      def show
        member = members_visible_to_viewer(User.non_service_accounts).find(params[:id])
        render json: { data: MemberSerializer.call(member) }
      end
    end
  end
end
