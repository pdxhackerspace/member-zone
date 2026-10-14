module Api
  module V1
    # Serves docs/api/openapi.yaml as JSON. Public: the reference describes the API, it grants
    # nothing, and clients and LLMs need it before they hold a token.
    class SpecsController < ActionController::API
      SPEC_PATH = Rails.root.join('docs/api/openapi.yaml')

      def self.spec
        @spec = nil if Rails.env.development?
        @spec ||= YAML.safe_load_file(SPEC_PATH, permitted_classes: [Date, Time]).freeze
      end

      def show
        render json: self.class.spec
      end
    end
  end
end
