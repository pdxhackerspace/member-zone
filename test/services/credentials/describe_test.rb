require 'test_helper'

module Credentials
  class DescribeTest < ActiveSupport::TestCase
    test 'stores the schema the program reports' do
      provider = create_credential_provider(describe: false, health: nil)
      assert_empty provider.schema_fields

      outcome = Describe.call(provider)

      assert outcome.ok?
      provider.reload
      assert_equal %w[client_id client_secret], provider.schema_fields.pluck('key')
      assert_equal [false, true], provider.schema_fields.pluck('secret')
      assert provider.supports_pause?
      assert_nil provider.schema_error
      assert_not_nil provider.schema_fetched_at
      assert provider.schema_ready?
    end

    test 'records a run' do
      provider = create_credential_provider(describe: false)
      assert_difference -> { provider.credential_runs.where(action: 'describe', status: 'success').count } => 1 do
        Describe.call(provider)
      end
    end

    test 'a program without pause is described as such' do
      provider = create_credential_provider(script: 'single_key.rb')
      assert_equal %w[api_key], provider.schema_fields.pluck('key')
      assert_not provider.supports_pause?
    end

    test 'an unusable schema is recorded as an error and stores nothing' do
      provider = create_credential_provider(script: 'bad_describe.sh', describe: false)

      outcome = Describe.call(provider)

      assert_not outcome.ok?
      provider.reload
      assert_not provider.schema_ready?
      assert_match(/non-empty array/, provider.schema_error)
      assert_not_nil provider.schema_fetched_at
    end

    test 'a failed describe keeps the schema already cached' do
      provider = create_credential_provider
      provider.update_columns(script_path: '/nonexistent/credentials/nope.sh')

      outcome = Describe.call(provider)

      assert_not outcome.ok?
      provider.reload
      assert provider.schema_ready?, 'the previous schema stays in use'
      assert_equal Invocation::NOT_IN_CATALOG, provider.schema_error
    end

    test 'a later successful describe clears the error' do
      provider = create_credential_provider(describe: false)
      provider.update_columns(schema_error: 'old problem')
      Describe.call(provider)
      assert_nil provider.reload.schema_error
    end
  end
end
