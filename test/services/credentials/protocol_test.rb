require 'test_helper'

module Credentials
  class ProtocolTest < ActiveSupport::TestCase
    SCHEMA = [
      { 'key' => 'client_id', 'label' => 'Client ID', 'secret' => false },
      { 'key' => 'client_secret', 'label' => 'Client secret', 'secret' => true }
    ].freeze

    def describe_json(**overrides)
      JSON.generate({ protocol: 1, name: 'N', description: 'D',
                      fields: [{ key: 'api_key', label: 'API key', secret: true }],
                      actions: %w[issue revoke health] }.merge(overrides))
    end

    def assert_describe_error(message, **overrides)
      error = assert_raises(Protocol::Error) { Protocol.describe(describe_json(**overrides)) }
      assert_includes error.message, message
    end

    def issue_json(**overrides)
      JSON.generate({ external_id: 'ext-1', fields: { client_id: 'cid', client_secret: 'abcd-secret-value-wxyz' } }
                    .merge(overrides))
    end

    def assert_issue_error(message, json)
      error = assert_raises(Protocol::Error) { Protocol.issue(json, SCHEMA) }
      assert_includes error.message, message
      error
    end

    test 'describe normalizes a valid schema' do
      schema = Protocol.describe(describe_json(actions: %w[issue revoke health pause resume]))

      assert_equal 1, schema['protocol']
      assert_equal 'N', schema['name']
      assert_equal [{ 'key' => 'api_key', 'label' => 'API key', 'secret' => true }], schema['fields']
      assert_equal %w[issue revoke health pause resume], schema['actions']
    end

    test 'secret defaults to true and the label to the humanized key' do
      schema = Protocol.describe(describe_json(fields: [{ key: 'client_id' }]))
      assert_equal [{ 'key' => 'client_id', 'label' => 'Client', 'secret' => true }], schema['fields']
    end

    test 'name and description are optional' do
      schema = Protocol.describe(JSON.generate(protocol: 1, fields: [{ key: 'k' }], actions: %w[issue revoke health]))
      assert_not schema.key?('name')
      assert_not schema.key?('description')
    end

    test 'describe rejects malformed output' do
      assert_raises(Protocol::Error) { Protocol.describe('') }
      assert_raises(Protocol::Error) { Protocol.describe('nope') }
      assert_raises(Protocol::Error) { Protocol.describe('[1,2]') }
      assert_raises(Protocol::Error) { Protocol.describe('"string"') }
      assert_raises(Protocol::Error) { Protocol.describe('null') }
    end

    test 'describe checks the protocol version' do
      assert_describe_error('protocol must be 1', protocol: 2)
      assert_describe_error('protocol must be 1', protocol: '1')
      assert_describe_error('protocol must be 1', protocol: nil)
    end

    test 'describe checks fields' do
      assert_describe_error('non-empty array', fields: [])
      assert_describe_error('non-empty array', fields: nil)
      assert_describe_error('non-empty array', fields: 'api_key')
      assert_describe_error('each field must be an object', fields: ['api_key'])
      assert_describe_error('lowercase letters', fields: [{ key: 'API Key' }])
      assert_describe_error('lowercase letters', fields: [{ key: '1abc' }])
      assert_describe_error('lowercase letters', fields: [{ key: '' }])
      assert_describe_error('lowercase letters', fields: [{ label: 'no key' }])
      assert_describe_error('secret must be true or false', fields: [{ key: 'k', secret: 'yes' }])
      assert_describe_error('duplicate field k', fields: [{ key: 'k' }, { key: 'k' }])
      assert_describe_error('label must be a string', fields: [{ key: 'k', label: 5 }])
    end

    test 'describe checks actions' do
      assert_describe_error('array of strings', actions: 'issue')
      assert_describe_error('array of strings', actions: [1])
      assert_describe_error('array of strings', actions: nil)
      assert_describe_error('unknown action explode', actions: %w[issue revoke health explode])
      assert_describe_error('must include revoke', actions: %w[issue health])
      assert_describe_error('must include issue, revoke, health', actions: [])
    end

    test 'pause and resume come together or not at all' do
      assert_describe_error('together', actions: %w[issue revoke health pause])
      assert_describe_error('together', actions: %w[issue revoke health resume])
      assert Protocol.describe(describe_json(actions: %w[issue revoke health pause resume]))
    end

    test 'health parses ok and message' do
      assert_equal({ ok: true, message: 'fine' }, Protocol.health('{"ok":true,"message":"fine"}'))
      assert_equal({ ok: false, message: nil }, Protocol.health('{"ok":false}'))
    end

    test 'health rejects malformed output' do
      assert_raises(Protocol::Error) { Protocol.health('') }
      assert_raises(Protocol::Error) { Protocol.health('{}') }
      assert_raises(Protocol::Error) { Protocol.health('{"ok":"yes"}') }
      assert_raises(Protocol::Error) { Protocol.health('{"ok":true,"message":5}') }
    end

    test 'issue returns fields in schema order with the handle and expiry' do
      expiry = 30.days.from_now.utc.iso8601
      result = Protocol.issue(issue_json(expires_at: expiry), SCHEMA)

      assert_equal 'ext-1', result[:external_id]
      assert_equal %w[client_id client_secret], result[:fields].keys
      assert_equal 'abcd-secret-value-wxyz', result[:fields]['client_secret']
      assert_in_delta Time.iso8601(expiry), result[:expires_at], 1
    end

    test 'the expiry is optional' do
      assert_nil Protocol.issue(issue_json, SCHEMA)[:expires_at]
      assert_nil Protocol.issue(issue_json(expires_at: nil), SCHEMA)[:expires_at]
    end

    test 'an integer handle is accepted as a string' do
      assert_equal '42', Protocol.issue(issue_json(external_id: 42), SCHEMA)[:external_id]
    end

    test 'issue rejects a missing or malformed handle' do
      assert_issue_error('external_id', issue_json(external_id: nil))
      assert_issue_error('external_id', issue_json(external_id: ''))
      assert_issue_error('external_id', issue_json(external_id: '   '))
      assert_issue_error('external_id', issue_json(external_id: %w[a]))
      assert_issue_error('too long', issue_json(external_id: 'x' * 256))
    end

    test 'issue rejects missing, extra and non-string fields' do
      assert_issue_error('missing field client_secret declared by describe',
                         JSON.generate(external_id: 'e', fields: { client_id: 'c' }))
      assert_issue_error('1 unexpected field(s) not declared by describe',
                         JSON.generate(external_id: 'e', fields: { client_id: 'c', client_secret: 's', surprise: 'x' }))
      assert_issue_error('must be a non-empty string',
                         JSON.generate(external_id: 'e', fields: { client_id: 'c', client_secret: '' }))
      assert_issue_error('must be a non-empty string',
                         JSON.generate(external_id: 'e', fields: { client_id: 'c', client_secret: 12_345 }))
      assert_issue_error('must be a non-empty string',
                         JSON.generate(external_id: 'e', fields: { client_id: 'c', client_secret: nil }))
      assert_issue_error('fields must be an object', JSON.generate(external_id: 'e', fields: %w[a]))
      assert_issue_error('fields must be an object', JSON.generate(external_id: 'e'))
    end

    test 'issue rejects bad expiry' do
      assert_issue_error('ISO 8601', issue_json(expires_at: 'next tuesday'))
      assert_issue_error('ISO 8601', issue_json(expires_at: 12_345))
      assert_issue_error('ISO 8601', issue_json(expires_at: ''))
      assert_issue_error('in the past', issue_json(expires_at: 1.day.ago.utc.iso8601))
    end

    test 'issue rejects output that is not a JSON object' do
      assert_issue_error('not valid JSON', 'garbage')
      assert_issue_error('not valid JSON', '')
      assert_issue_error('not a JSON object', '[]')
      assert_issue_error('not a JSON object', '"abcd-secret-value-wxyz"')
    end

    test 'no error message ever repeats a value from the output' do
      secret = 'abcd-secret-value-wxyz'
      attempts = [
        "garbage #{secret}",
        JSON.generate(external_id: secret, fields: { client_id: 'c', client_secret: secret, extra: secret }),
        JSON.generate(external_id: secret, fields: { client_id: 'c', client_secret: secret, secret.to_sym => secret }),
        JSON.generate(external_id: 'e', fields: { client_id: 'c', client_secret: [secret] }),
        JSON.generate(external_id: 'e', fields: { client_id: secret }),
        JSON.generate(external_id: 'e', fields: { client_id: 'c', client_secret: secret }, expires_at: secret),
        JSON.generate(external_id: ['x', secret], fields: {}),
        JSON.generate(external_id: secret * 20, fields: {})
      ]
      attempts.each do |output|
        error = assert_raises(Protocol::Error, output) { Protocol.issue(output, SCHEMA) }
        assert_not_includes error.message, secret, "message leaked a value for: #{output[0, 60]}"
      end
    end

    test 'neither the names nor the values of unexpected fields are echoed' do
      error = assert_raises(Protocol::Error) do
        fields = { client_id: 'c', client_secret: 's', SECRETNAME: 'SECRETVALUE' }
        Protocol.issue(JSON.generate(external_id: 'e', fields: fields), SCHEMA)
      end
      assert_not_includes error.message, 'SECRETVALUE'
      assert_not_includes error.message, 'SECRETNAME'
    end

    test 'external_id_from recovers the handle from output that failed validation' do
      assert_equal 'ext-9', Protocol.external_id_from(JSON.generate(external_id: 'ext-9', fields: {}))
      assert_equal 'ext-9', Protocol.external_id_from(JSON.generate(external_id: ' ext-9 ', fields: 'junk'))
    end

    test 'external_id_from returns nil when there is nothing to recover' do
      assert_nil Protocol.external_id_from('garbage')
      assert_nil Protocol.external_id_from('[]')
      assert_nil Protocol.external_id_from('{}')
      assert_nil Protocol.external_id_from(JSON.generate(external_id: ''))
      assert_nil Protocol.external_id_from(nil)
    end
  end
end
