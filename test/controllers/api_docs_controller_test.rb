require 'test_helper'

class ApiDocsControllerTest < ActionDispatch::IntegrationTest
  test 'llms.txt indexes every operation with its scope' do
    get llms_txt_path

    assert_response :success
    assert_equal 'text/markdown', response.media_type
    assert response.body.start_with?("# Member Zone API\n\n> ")
    assert_includes response.body, 'http://www.example.com/api/v1/openapi.json'
    ApiReference::Document.current.operations.each do |method, path, _operation|
      assert_includes response.body, "`#{method} /api/v1#{path}`"
    end
    assert_includes response.body, '(scope: `parking.manage_notices`)'
  end

  test 'llms-full.txt carries the guide and every endpoint' do
    get api_v1_llms_full_path

    assert_response :success
    assert_equal 'text/markdown', response.media_type
    assert_includes response.body, '# Member Zone API guide'
    assert_includes response.body, '# Endpoint reference'
    ApiReference::Document.current.operations.each do |method, path, _operation|
      assert_includes response.body, "## #{method} /api/v1#{path}"
    end
    assert_includes response.body, '- Scope: none (no token needed)'
    assert_includes response.body, '- Scope: none (any valid token)'
    assert_includes response.body, '- Body (multipart/form-data):'
    assert_includes response.body, '  - `printer_id` (required): integer'
    assert_includes response.body, '  - `type` (query, one of: permit, ticket)'
    assert_includes response.body, '# Schemas'
    assert_includes response.body, '## ParkingNotice'
  end

  test 'the rendered reference loads the spec' do
    get api_docs_path

    assert_response :success
    assert_select 'redoc[spec-url=?]', api_v1_openapi_path
    assert_select 'script[src*="redoc@"][integrity]'
  end

  test 'none of it needs a token or a session' do
    [llms_txt_path, api_v1_llms_full_path, api_docs_path, api_v1_openapi_path].each do |path|
      get path
      assert_response :success, path
    end
  end
end
