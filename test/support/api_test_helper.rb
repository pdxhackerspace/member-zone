# Helpers for the token-authenticated API: issuing tokens, sending them, and checking responses
# against docs/api/openapi.yaml so the reference cannot drift from what the API returns.
module ApiTestHelper
  SPEC_PATH = Rails.root.join('docs/api/openapi.yaml')

  def self.spec
    @spec ||= YAML.safe_load_file(SPEC_PATH, permitted_classes: [Date, Time])
  end

  def self.schemer
    @schemer ||= JSONSchemer.openapi(spec)
  end

  # Returns the plaintext token. Extra attributes go straight to ApiToken.
  def issue_api_token(user, scopes: [], created_by: user, **attrs)
    token = ApiToken.create!(user: user, created_by: created_by, name: "Test token #{SecureRandom.hex(3)}",
                             scopes: scopes, **attrs)
    token.token
  end

  def api_headers(raw_token)
    { 'Authorization' => "Bearer #{raw_token}", 'Accept' => 'application/json' }
  end

  def create_service_account(**attrs)
    User.create!({
      authentik_id: "sa-#{SecureRandom.hex(4)}",
      full_name: "Service Account #{SecureRandom.hex(4)}",
      payment_type: 'unknown',
      service_account: true,
      active: true
    }.merge(attrs))
  end

  def json_body
    response.parsed_body
  end

  def assert_api_error(status, code)
    assert_response status
    assert_equal code, json_body.dig('error', 'code'), response.body
  end

  # Checks the last response against the spec's schema for this operation and status. The path
  # is the spec's template, e.g. '/members/{id}'.
  def assert_matches_spec(method, path)
    operation = ApiTestHelper.spec.dig('paths', path, method.to_s)
    assert operation, "docs/api/openapi.yaml has no #{method.upcase} #{path}"

    status = response.status.to_s
    assert operation['responses'].key?(status),
           "docs/api/openapi.yaml does not document #{status} for #{method.upcase} #{path}"
    return unless response.media_type == 'application/json'

    schema = ApiTestHelper.response_schema(operation['responses'][status])
    return if schema.nil?

    errors = ApiTestHelper.schemer_for(schema).validate(json_body).pluck('error')
    assert_empty errors, "#{method.upcase} #{path} #{status} does not match the spec: #{response.body}"
  end

  # The JSON schema for a response object, following a $ref to components/responses.
  def self.response_schema(response_object)
    response_object = resolve(response_object['$ref']) while response_object.key?('$ref')
    response_object.dig('content', 'application/json', 'schema')
  end

  def self.resolve(ref)
    spec.dig(*ref.delete_prefix('#/').split('/').map { |part| part.gsub('~1', '/').gsub('~0', '~') })
  end

  # A validator for +schema+ whose $refs resolve against the whole spec: the schema's keywords are
  # laid over the spec document, so '#/components/schemas/…' still points where it should.
  def self.schemer_for(schema)
    JSONSchemer.schema(spec.merge(schema))
  end
end
