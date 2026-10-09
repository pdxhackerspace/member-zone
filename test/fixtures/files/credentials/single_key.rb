#!/usr/bin/env ruby
# One secret field, no pause or resume. Written in Ruby to prove any interpreter works.
require 'json'
require 'securerandom'

action = ARGV.fetch(0)
input = $stdin.read.to_s
request = input.empty? ? {} : JSON.parse(input)

case action
when 'describe'
  puts JSON.generate(protocol: 1, name: 'Fixture API key', description: 'A single API key.',
                     fields: [{ key: 'api_key', label: 'API key', secret: true }],
                     actions: %w[issue revoke health])
when 'health'
  puts JSON.generate(ok: true, message: 'ok')
when 'issue'
  puts JSON.generate(external_id: "key-#{request['request_id']}",
                     fields: { api_key: ENV.fetch('API_KEY_VALUE', "key_#{SecureRandom.hex(16)}") })
when 'revoke'
  exit(ENV['FAIL_REVOKE'] ? 1 : 0)
else
  warn 'unknown action'
  exit 64
end
