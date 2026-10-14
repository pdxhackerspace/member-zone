module Api
  module V1
    # Unknown /api/v1 paths answer in the API's error envelope rather than with an HTML page.
    class ErrorsController < ActionController::API
      def not_found
        render json: { error: { code: 'not_found', message: 'No such API endpoint.', details: {} } },
               status: :not_found
      end
    end
  end
end
