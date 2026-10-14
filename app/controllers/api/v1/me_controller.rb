module Api
  module V1
    # Who a token belongs to and what it may do. Needs no scope: any valid token may ask about
    # itself, which is how a client checks its configuration.
    class MeController < BaseController
      def show
        render json: { data: TokenSerializer.call(current_api_token) }
      end
    end
  end
end
