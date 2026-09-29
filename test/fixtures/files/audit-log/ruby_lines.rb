#!/usr/bin/env ruby
# Reports RUBYOPT so a test can tell whether the Rails app's Bundler setup leaked into this process.
require 'json'
puts({ timestamp: '2026-09-29T12:00:00Z', message: 'ruby says hello', id: 'r1',
       rubyopt: ENV.fetch('RUBYOPT', '') }.to_json)
