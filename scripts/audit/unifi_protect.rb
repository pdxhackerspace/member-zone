#!/usr/bin/env ruby
# Member Zone audit log program: UniFi Protect events.
#
# Listens to the console's Integration API event stream for a fixed window and prints one JSON
# line per event on stdout, in the format described in docs/audit-logs.md. Diagnostics go to
# stderr; a non-zero exit marks the run failed, and Member Zone keeps whatever was printed.
#
# IMPORTANT LIMITATION: the Integration API that an API key can reach has no history endpoint.
# Events arrive only while a connection is open, so anything that happens between runs is not
# seen. Lengthen UNIFI_LISTEN_SECONDS (Member Zone stops a run after 10 minutes) and schedule
# the source often; it is a sample of activity, not a complete record.
#
# Environment:
#   UNIFI_API_KEY         required. An API key from UniFi OS > Control Plane > Integrations.
#   UNIFI_HOST            required. Console address, optionally with a port: 192.168.1.1 or unifi.lan:8443
#   UNIFI_LISTEN_SECONDS  optional. How long to listen (default 240, at most 540).
#   UNIFI_CA_FILE         optional. PEM file to trust, for a console with a private CA.
#   UNIFI_INSECURE        optional. Set to 1 to skip certificate verification (self-signed consoles).
#   UNIFI_SCHEME          optional. https (default) or http. Plain http is only meant for testing.
#
# The stdlib is all it needs, so it runs under any Ruby with no gems installed.

require 'base64'
require 'json'
require 'net/http'
require 'openssl'
require 'securerandom'
require 'socket'
require 'time'
require 'uri'

module UnifiProtect
  API_PATH = '/proxy/protect/integration/v1'.freeze
  DEFAULT_LISTEN_SECONDS = 240
  MAX_LISTEN_SECONDS = 540
  # Device families whose names are fetched so entries can say "Front door" rather than an id.
  DEVICE_COLLECTIONS = %w[cameras sensors doorlocks chimes lights].freeze

  class ConfigError < StandardError; end
  class AuthError < StandardError; end

  Config = Struct.new(:host, :api_key, :listen_seconds, :ca_file, :insecure, :scheme, keyword_init: true) do
    def self.from_env(env = ENV)
      host = env['UNIFI_HOST'].to_s.strip
      key = env['UNIFI_API_KEY'].to_s.strip
      raise ConfigError, 'UNIFI_HOST is not set' if host.empty?
      raise ConfigError, 'UNIFI_API_KEY is not set' if key.empty?

      new(host: host, api_key: key, listen_seconds: listen_seconds(env['UNIFI_LISTEN_SECONDS']),
          ca_file: env['UNIFI_CA_FILE'].to_s.strip.then { |v| v.empty? ? nil : v },
          insecure: %w[1 true yes].include?(env['UNIFI_INSECURE'].to_s.downcase),
          scheme: env['UNIFI_SCHEME'].to_s.downcase == 'http' ? 'http' : 'https')
    end

    def self.listen_seconds(value)
      seconds = value.to_s.strip.empty? ? DEFAULT_LISTEN_SECONDS : Integer(value, 10)
      raise ConfigError, 'UNIFI_LISTEN_SECONDS must be positive' unless seconds.positive?

      [seconds, MAX_LISTEN_SECONDS].min
    rescue ArgumentError
      raise ConfigError, "UNIFI_LISTEN_SECONDS is not a number: #{value.inspect}"
    end

    def base_url
      "#{scheme}://#{host}#{API_PATH}"
    end

    def ws_url
      "#{scheme == 'http' ? 'ws' : 'wss'}://#{host}#{API_PATH}/subscribe/events"
    end
  end

  # Builds the connection options shared by the REST lookups and the event stream.
  module Tls
    module_function

    def context(config)
      ctx = OpenSSL::SSL::SSLContext.new
      ctx.set_params(verify_mode: config.insecure ? OpenSSL::SSL::VERIFY_NONE : OpenSSL::SSL::VERIFY_PEER)
      ctx.ca_file = config.ca_file if config.ca_file
      ctx
    end
  end

  # Device id => name, so entries are readable. Best effort: a family that cannot be fetched is
  # skipped, and an unknown id is printed as the id.
  class DeviceNames
    def self.fetch(config, warn_io: $stderr)
      DEVICE_COLLECTIONS.each_with_object({}) do |collection, names|
        get_json(config, collection)&.each { |device| names[device['id']] = device['name'] if device.is_a?(Hash) }
      rescue AuthError
        raise
      rescue StandardError => e
        warn_io.puts "could not list #{collection}: #{e.class}: #{e.message}"
      end
    end

    def self.get_json(config, collection)
      uri = URI("#{config.base_url}/#{collection}")
      response = request(config, uri)
      raise AuthError, "HTTP #{response.code} from #{uri.path}" if %w[401 403].include?(response.code)
      return nil unless response.is_a?(Net::HTTPSuccess)

      parsed = JSON.parse(response.body)
      parsed.is_a?(Array) ? parsed : nil
    end

    def self.request(config, uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.open_timeout = http.read_timeout = 10
      if uri.scheme == 'https'
        http.use_ssl = true
        http.verify_mode = config.insecure ? OpenSSL::SSL::VERIFY_NONE : OpenSSL::SSL::VERIFY_PEER
        http.ca_file = config.ca_file if config.ca_file
      end
      http.request(Net::HTTP::Get.new(uri, 'X-API-KEY' => config.api_key, 'Accept' => 'application/json'))
    end
  end

  # A minimal RFC 6455 client: enough to hold one text-message stream open. It exists so the
  # script needs no gems.
  class WebSocket
    GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'.freeze
    class Closed < StandardError; end

    def initialize(config, deadline)
      @config = config
      @deadline = deadline
      @buffer = ''.b
    end

    def open
      uri = URI(@config.ws_url)
      @io = connect(uri)
      handshake(uri)
      self
    end

    # Yields each complete text message until the deadline passes or the server closes.
    def each_message(&)
      message = nil
      loop do
        opcode, fin, payload = read_frame
        case opcode
        when 0, 1, 2 then message = assemble(message, opcode, payload, fin, &)
        when 8 then return close_from_server(payload)
        when 9 then send_frame(10, payload)
        end
      end
    rescue Closed
      nil
    end

    def close
      send_frame(8, [1000].pack('n')) unless @io.nil? || @io.closed?
    rescue StandardError
      nil
    ensure
      @io&.close unless @io&.closed?
    end

    private

    def connect(uri)
      tcp = Socket.tcp(uri.host, uri.port, connect_timeout: 10)
      return tcp unless uri.scheme == 'wss'

      ssl = OpenSSL::SSL::SSLSocket.new(tcp, Tls.context(@config))
      ssl.hostname = uri.host
      ssl.sync_close = true
      ssl.connect
      ssl.post_connection_check(uri.host) unless @config.insecure
      ssl
    end

    def handshake(uri)
      key = SecureRandom.base64(16)
      host = uri.port == uri.default_port ? uri.host : "#{uri.host}:#{uri.port}"
      write("GET #{uri.request_uri} HTTP/1.1\r\nHost: #{host}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
            "Sec-WebSocket-Key: #{key}\r\nSec-WebSocket-Version: 13\r\nX-API-KEY: #{@config.api_key}\r\n\r\n")
      status = read_line
      headers = read_headers
      verify_upgrade(status, headers, key)
    end

    def read_headers
      headers = {}
      while (line = read_line) && !line.empty?
        name, value = line.split(':', 2)
        headers[name.to_s.strip.downcase] = value.to_s.strip
      end
      headers
    end

    def verify_upgrade(status, headers, key)
      code = status.to_s[%r{\AHTTP/1\.[01] (\d{3})}, 1]
      raise AuthError, "HTTP #{code} opening the event stream" if %w[401 403].include?(code)
      raise "event stream refused: #{status}" unless code == '101'

      expected = Base64.strict_encode64(OpenSSL::Digest::SHA1.digest(key + GUID))
      raise 'event stream handshake was not accepted' unless headers['sec-websocket-accept'] == expected
    end

    def assemble(partial, opcode, payload, fin)
      data = opcode.zero? ? "#{partial}#{payload}" : payload
      return data unless fin

      yield data.dup.force_encoding(Encoding::UTF_8) unless opcode == 2
      nil
    end

    def close_from_server(payload)
      send_frame(8, payload[0, 2].to_s)
    rescue StandardError
      nil
    end

    def read_frame
      head = read_bytes(2).bytes
      opcode = head[0] & 0x0f
      length = head[1] & 0x7f
      length = read_bytes(2).unpack1('n') if length == 126
      length = read_bytes(8).unpack1('Q>') if length == 127
      mask = head[1].nobits?(0x80) ? nil : read_bytes(4).bytes
      payload = read_bytes(length)
      payload = payload.bytes.each_with_index.map { |byte, i| byte ^ mask[i % 4] }.pack('C*') if mask
      [opcode, head[0].anybits?(0x80), payload]
    end

    # Client frames must be masked.
    def send_frame(opcode, payload)
      mask = SecureRandom.random_bytes(4)
      masked = payload.bytes.each_with_index.map { |byte, i| byte ^ mask.getbyte(i % 4) }.pack('C*')
      write([0x80 | opcode, 0x80 | payload.bytesize].pack('CC') + mask + masked)
    end

    def write(data)
      @io.write(data)
    end

    def read_line
      fill until (index = @buffer.index("\r\n".b))
      @buffer.slice!(0, index + 2).chomp.force_encoding(Encoding::UTF_8)
    end

    def read_bytes(count)
      fill while @buffer.bytesize < count
      @buffer.slice!(0, count)
    end

    def fill
      remaining = @deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raise Closed if remaining <= 0

      chunk = @io.read_nonblock(16_384, exception: false)
      case chunk
      when :wait_readable then @io.to_io.wait_readable([remaining, 1].min)
      when nil then raise Closed
      else @buffer << chunk.b
      end
    end
  end

  # Turns one Integration API event message into the audit log JSON the program prints.
  class EventFormatter
    def initialize(names = {})
      @names = names
    end

    # Returns a Hash ready for JSON, or nil for a message that is not a device event.
    def call(text, now: Time.now.utc)
      message = JSON.parse(text)
      item = message['item'] if message.is_a?(Hash)
      return nil unless item.is_a?(Hash)
      return nil if item['modelKey'] && item['modelKey'] != 'event'
      return nil if item['type'].to_s.empty?

      build(message['type'].to_s, item, now)
    rescue JSON::ParserError
      nil
    end

    private

    def build(change, item, now)
      device = item['device'] || item['deviceId']
      name = @names[device] || device
      {
        timestamp: time_of(item, now).iso8601(3),
        message: describe(change, item, name),
        id: "#{item['id']}:#{change}:#{item['end'] || 'open'}",
        source: 'unifi-protect', event: item['type'], device: device, device_name: name,
        change: change, smart_detect_types: item['smartDetectTypes']
      }.compact
    end

    def describe(change, item, name)
      subject = name ? "#{name}: " : ''
      detects = Array(item['smartDetectTypes']).then { |t| t.empty? ? '' : " (#{t.join(', ')})" }
      "#{subject}#{item['type']}#{detects} #{state_of(change, item)}"
    end

    def state_of(change, item)
      return 'ended' if item['end']

      change == 'add' ? 'started' : 'updated'
    end

    # start/end are epoch milliseconds; the newest of them is when this message happened.
    def time_of(item, now)
      millis = [item['end'], item['start']].compact.first
      millis.is_a?(Numeric) ? Time.at(millis / 1000.0).utc : now
    end
  end

  class Runner
    RETRY_DELAY = 2

    def initialize(config, out: $stdout, err: $stderr)
      @config = config
      @out = out
      @err = err
    end

    def call
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @config.listen_seconds
      formatter = EventFormatter.new(DeviceNames.fetch(@config, warn_io: @err))
      failures = 0
      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        failures = listen(deadline, formatter) ? 0 : failures + 1
        return fail_run('event stream kept failing') if failures >= 3

        sleep(RETRY_DELAY) if Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      end
      0
    rescue ConfigError, AuthError => e
      fail_run(e.message)
    end

    private

    # One connection. Returns true when it ran cleanly, false when it could not be held open.
    def listen(deadline, formatter)
      socket = WebSocket.new(@config, deadline).open
      socket.each_message do |text|
        entry = formatter.call(text)
        @out.puts(JSON.generate(entry)) if entry
        @out.flush
      end
      true
    rescue AuthError
      raise
    rescue StandardError => e
      @err.puts "event stream error: #{e.class}: #{e.message}"
      false
    ensure
      socket&.close
    end

    def fail_run(message)
      @err.puts(message)
      1
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    exit UnifiProtect::Runner.new(UnifiProtect::Config.from_env).call
  rescue UnifiProtect::ConfigError => e
    warn e.message
    exit 2
  end
end
