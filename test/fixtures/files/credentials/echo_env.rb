#!/usr/bin/env ruby
# Reports its environment, arguments and stdin as JSON, to prove what reaches a program.
require 'json'

puts JSON.generate(env: ENV.to_h, argv: ARGV, stdin: $stdin.read.to_s)
