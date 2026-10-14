require 'test_helper'

module Api
  module V1
    # Keeps docs/api/openapi.yaml honest: it is served, it is a valid OpenAPI document, every
    # /api/v1 route is in it and everything in it is routed, and its examples match its schemas.
    class SpecContractTest < ActionDispatch::IntegrationTest
      # Routes that exist for plumbing rather than as operations.
      UNDOCUMENTED_ROUTES = ['* /*path'].freeze
      HTTP_METHODS = %w[get put post delete options head patch trace].freeze

      test 'the spec is served as JSON without a token' do
        get api_v1_openapi_path

        assert_response :success
        assert_equal '3.1.0', json_body['openapi']
        assert json_body['paths'].key?('/me')
      end

      test 'the spec is a valid OpenAPI 3.1 document' do
        errors = JSONSchemer.openapi(ApiTestHelper.spec).validate.pluck('error')

        assert_empty errors
      end

      test 'every API route is documented and every documented operation is routed' do
        routed = api_routes.to_set { |verb, path| "#{verb} #{path}" }
        # Rails routes PUT alongside PATCH for updates; the spec documents PATCH and says so.
        routed.reject! { |route| route.start_with?('PUT ') && routed.include?(route.sub('PUT ', 'PATCH ')) }
        documented = ApiTestHelper.spec['paths'].flat_map do |path, operations|
          operations.keys.intersection(HTTP_METHODS).map { |verb| "#{verb.upcase} #{path}" }
        end.to_set

        assert_empty (routed - documented - UNDOCUMENTED_ROUTES).sort, 'routes missing from docs/api/openapi.yaml'
        assert_empty (documented - routed).sort, 'docs/api/openapi.yaml documents routes that do not exist'
      end

      test 'every operation names its scope and documents 401 unless it is public' do
        each_operation do |label, operation|
          next if operation['security'] == []

          assert operation.key?('x-required-scope'), "#{label} does not say which scope it needs"
          assert operation['responses'].key?('401'), "#{label} does not document 401"
        end
      end

      test 'every response example matches its schema' do
        each_operation do |label, operation|
          operation['responses'].each do |status, response_object|
            example = example_for(response_object)
            schema = ApiTestHelper.response_schema(response_object)
            next if example.nil? || schema.nil?

            errors = ApiTestHelper.schemer_for(schema).validate(example).pluck('error')
            assert_empty errors, "#{label} #{status} example does not match its schema"
          end
        end
      end

      private

      def api_routes
        Rails.application.routes.routes.filter_map do |route|
          path = route.path.spec.to_s.delete_suffix('(.:format)')
          next unless path.start_with?('/api/v1/')

          verb = route.verb.presence || '*'
          [verb, path.delete_prefix('/api/v1').gsub(/:(\w+)/, '{\1}')]
        end.uniq
      end

      def each_operation(&)
        ApiTestHelper.spec['paths'].each do |path, operations|
          operations.slice(*HTTP_METHODS).each { |verb, operation| yield("#{verb.upcase} #{path}", operation) }
        end
      end

      def example_for(response_object)
        response_object = ApiTestHelper.resolve(response_object['$ref']) while response_object.key?('$ref')
        response_object.dig('content', 'application/json', 'example')
      end
    end
  end
end
