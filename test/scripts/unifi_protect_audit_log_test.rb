require 'test_helper'
require 'socket'
require 'digest'
require 'open3'
require Rails.root.join('scripts/audit-log/unifi_protect')

# scripts/audit-log/unifi_protect.rb is a standalone program Member Zone runs as an audit log
# source. These tests drive it against a small fake console that speaks just enough HTTP and
# WebSocket, and finish by running it through the same path a scheduled run takes.
class UnifiProtectAuditLogTest < ActiveSupport::TestCase
  SCRIPT = Rails.root.join('scripts/audit-log/unifi_protect.rb').to_s
  KEY = 'test-api-key'.freeze
  GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'.freeze

  # A console stand-in. `script` lists what to send after the upgrade: [:text, str], [:binary, str],
  # [:ping, str], [:fragments, [str, str]], [:sleep, seconds]. Then it closes, or holds the
  # connection open when `hold` is set.
  class FakeConsole
    attr_reader :port, :client_bytes, :paths

    def initialize(cameras: [], script: [], hold: false, api_key: KEY)
      @cameras = cameras
      @script = script
      @hold = hold
      @api_key = api_key
      @client_bytes = ''.b
      @paths = []
      @server = TCPServer.new('127.0.0.1', 0)
      @port = @server.addr[1]
      @thread = Thread.new { accept_loop }
    end

    def stop
      @thread.kill
      @server.close
    end

    def frame(opcode, payload, fin: true)
      payload = payload.b
      size = payload.bytesize
      head = [(fin ? 0x80 : 0) | opcode].pack('C')
      head += if size < 126 then [size].pack('C')
              elsif size < 65_536 then [126, size].pack('Cn')
              else [127, size].pack('CQ>')
              end
      head + payload
    end

    private

    def accept_loop
      loop { Thread.new(@server.accept) { |client| serve(client) } }
    rescue IOError, Errno::EBADF
      nil
    end

    def serve(client)
      request = client.gets.to_s
      headers = read_headers(client)
      @paths << request.split[1]
      return respond(client, 401, 'unauthorized') unless headers['x-api-key'] == @api_key

      if headers['upgrade'].to_s.casecmp?('websocket')
        upgrade(client, headers)
      else
        respond(client, 200, @cameras_for_path.to_json, path: request.split[1])
      end
    ensure
      client.close unless client.closed?
    end

    def read_headers(client)
      headers = {}
      while (line = client.gets) && line != "\r\n"
        name, value = line.split(':', 2)
        headers[name.downcase] = value.strip
      end
      headers
    end

    def respond(client, status, body, path: nil)
      body = collection_for(path) if path
      client.write("HTTP/1.1 #{status} X\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\n" \
                   "Connection: close\r\n\r\n#{body}")
    end

    def collection_for(path)
      path.end_with?('/cameras') ? @cameras.to_json : '[]'
    end

    def upgrade(client, headers)
      accept = [Digest::SHA1.digest(headers['sec-websocket-key'] + GUID)].pack('m0')
      client.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
                   "Sec-WebSocket-Accept: #{accept}\r\n\r\n")
      @script.each { |step| play(client, step) }
      @hold ? drain(client, 30) : close_and_drain(client)
    end

    def play(client, step)
      kind, value = step
      case kind
      when :text then client.write(frame(1, value))
      when :binary then client.write(frame(2, value))
      when :ping then client.write(frame(9, value))
      when :sleep then sleep(value)
      when :fragments
        client.write(frame(1, value[0], fin: false))
        client.write(frame(0, value[1]))
      end
    end

    def close_and_drain(client)
      client.write(frame(8, [1000].pack('n')))
      drain(client, 1)
    end

    def drain(client, seconds)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        client.wait_readable(0.2)
        chunk = client.read_nonblock(4096, exception: false)
        break if chunk.nil?

        @client_bytes << chunk if chunk.is_a?(String)
      end
    end
  end

  def config(console, **overrides)
    UnifiProtect::Config.new(host: "127.0.0.1:#{console.port}", api_key: KEY, listen_seconds: 2, ca_file: nil,
                             insecure: false, scheme: 'http', **overrides)
  end

  def with_console(**)
    console = FakeConsole.new(**)
    yield console
  ensure
    console&.stop
  end

  def event(type: 'motion', id: 'evt1', device: 'cam1', **extra)
    item = { id: id, modelKey: 'event', type: type, start: 1_790_679_900_000, device: device }
    { type: 'add', item: item.merge(extra) }
  end

  # --- Config ---

  test 'config requires a host and an API key' do
    assert_raises(UnifiProtect::ConfigError) { UnifiProtect::Config.from_env('UNIFI_API_KEY' => 'k') }
    error = assert_raises(UnifiProtect::ConfigError) { UnifiProtect::Config.from_env('UNIFI_HOST' => 'h') }
    assert_match(/UNIFI_API_KEY/, error.message)
    assert_raises(UnifiProtect::ConfigError) { UnifiProtect::Config.from_env('UNIFI_HOST' => ' ', 'UNIFI_API_KEY' => 'k') }
  end

  test 'config defaults to https, a four minute window and strict TLS' do
    config = UnifiProtect::Config.from_env('UNIFI_HOST' => 'unifi.lan', 'UNIFI_API_KEY' => 'k')

    assert_equal 240, config.listen_seconds
    assert_equal 'https', config.scheme
    assert_not config.insecure
    assert_nil config.ca_file
    assert_equal 'https://unifi.lan/proxy/protect/integration/v1', config.base_url
    assert_equal 'wss://unifi.lan/proxy/protect/integration/v1/subscribe/events', config.ws_url
  end

  test 'config reads the optional settings' do
    config = UnifiProtect::Config.from_env('UNIFI_HOST' => '10.0.0.1:8443', 'UNIFI_API_KEY' => 'k',
                                           'UNIFI_LISTEN_SECONDS' => '60', 'UNIFI_INSECURE' => 'YES',
                                           'UNIFI_CA_FILE' => '/etc/ca.pem', 'UNIFI_SCHEME' => 'HTTP')

    assert_equal 60, config.listen_seconds
    assert config.insecure
    assert_equal '/etc/ca.pem', config.ca_file
    assert_equal 'ws://10.0.0.1:8443/proxy/protect/integration/v1/subscribe/events', config.ws_url
  end

  test 'the listening window is capped below Member Zone run timeout and must be a positive number' do
    base = { 'UNIFI_HOST' => 'h', 'UNIFI_API_KEY' => 'k' }

    assert_equal 540, UnifiProtect::Config.from_env(base.merge('UNIFI_LISTEN_SECONDS' => '9999')).listen_seconds
    assert_operator UnifiProtect::MAX_LISTEN_SECONDS.seconds, :<, AuditLogs::ScriptRunner::TIMEOUT
    %w[0 -5 abc 1.5].each do |bad|
      assert_raises(UnifiProtect::ConfigError, bad) { UnifiProtect::Config.from_env(base.merge('UNIFI_LISTEN_SECONDS' => bad)) }
    end
  end

  # --- EventFormatter ---

  test 'formats a started event with the device name and an ISO8601 time from the event start' do
    entry = UnifiProtect::EventFormatter.new('cam1' => 'Front door').call(event.to_json)

    assert_equal '2026-09-29T11:05:00.000Z', entry[:timestamp]
    assert_equal 'Front door: motion started', entry[:message]
    assert_equal 'evt1:add:open', entry[:id]
    assert_equal({ event: 'motion', device: 'cam1', device_name: 'Front door', change: 'add' },
                 entry.slice(:event, :device, :device_name, :change))
  end

  test 'an update that carries an end is described as ended and takes the end time' do
    message = event(end: 1_790_679_960_000).merge(type: 'update')
    entry = UnifiProtect::EventFormatter.new('cam1' => 'Front door').call(message.to_json)

    assert_equal 'Front door: motion ended', entry[:message]
    assert_equal '2026-09-29T11:06:00.000Z', entry[:timestamp]
    assert_equal 'evt1:update:1790679960000', entry[:id]
  end

  test 'an open update is described as updated, and smart detections are listed' do
    entry = UnifiProtect::EventFormatter.new.call(
      event(type: 'smartDetectZone', smartDetectTypes: %w[person vehicle]).merge(type: 'update').to_json
    )

    assert_equal 'cam1: smartDetectZone (person, vehicle) updated', entry[:message]
    assert_equal %w[person vehicle], entry[:smart_detect_types]
  end

  test 'a device with an unknown id is printed by id, and an event with no device has no prefix' do
    unknown = UnifiProtect::EventFormatter.new.call(event(type: 'ring', device: 'cam9').to_json)
    assert_equal 'cam9: ring started', unknown[:message]

    bare = event(type: 'ring')
    bare[:item].delete(:device)
    assert_equal 'ring started', UnifiProtect::EventFormatter.new.call(bare.to_json)[:message]
  end

  test 'ids differ between the start and the end of one event, so both are stored' do
    formatter = UnifiProtect::EventFormatter.new
    started = formatter.call(event.to_json)
    ended = formatter.call(event(end: 1_790_679_960_000).merge(type: 'update').to_json)

    assert_not_equal started[:id], ended[:id]
    assert_equal started[:id], formatter.call(event.to_json)[:id], 'the same message always gets the same id'
  end

  test 'a message without a usable time is stamped with now' do
    now = Time.utc(2026, 1, 2, 3, 4, 5)
    message = event
    message[:item].delete(:start)

    entry = UnifiProtect::EventFormatter.new.call(message.to_json, now: now)
    assert_equal '2026-01-02T03:04:05.000Z', entry[:timestamp]
  end

  test 'messages that are not device events are ignored' do
    formatter = UnifiProtect::EventFormatter.new

    assert_nil formatter.call('not json')
    assert_nil formatter.call('[1, 2]')
    assert_nil formatter.call('{"type": "add"}')
    assert_nil formatter.call({ type: 'update', item: { id: 'c1', modelKey: 'camera', name: 'x' } }.to_json)
    assert_nil formatter.call({ type: 'add', item: { id: 'e', modelKey: 'event' } }.to_json)
  end

  test 'every printed entry is valid input for Member Zone' do
    line = JSON.generate(UnifiProtect::EventFormatter.new('cam1' => 'Front door').call(event.to_json))
    parsed = AuditLogs::OutputParser.call("#{line}\n", run_at: Time.zone.parse('2026-09-29 16:00')).sole

    assert_equal 'Front door: motion started', parsed[:message]
    assert_equal Time.utc(2026, 9, 29, 11, 5), parsed[:occurred_at].utc
    assert_equal 'Front door', parsed[:raw]['device_name']
  end

  # --- WebSocket ---

  def read_messages(console, seconds: 2)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    socket = UnifiProtect::WebSocket.new(config(console), deadline).open
    messages = []
    socket.each_message { |text| messages << text }
    socket.close
    messages
  end

  test 'receives text messages and stops when the server closes' do
    with_console(script: [[:text, 'one'], [:text, 'two']]) do |console|
      assert_equal %w[one two], read_messages(console)
    end
  end

  test 'sends the API key when opening the stream and asks for the events path' do
    with_console(script: []) do |console|
      read_messages(console)

      assert_equal ['/proxy/protect/integration/v1/subscribe/events'], console.paths
    end
  end

  test 'reassembles fragmented messages and ignores binary frames' do
    with_console(script: [[:fragments, %w[hel lo]], [:binary, "\x00\x01"], [:text, 'after']]) do |console|
      assert_equal %w[hello after], read_messages(console)
    end
  end

  test 'reads long messages, both the 16 bit and the 64 bit length forms' do
    medium = 'm' * 300
    large = 'l' * 70_000
    with_console(script: [[:text, medium], [:text, large]]) do |console|
      assert_equal [medium, large], read_messages(console)
    end
  end

  test 'decodes UTF-8 text' do
    with_console(script: [[:text, 'Café ☕']]) do |console|
      message = read_messages(console).sole
      assert_equal 'Café ☕', message
      assert_equal Encoding::UTF_8, message.encoding
    end
  end

  test 'answers a ping with a masked pong carrying the same payload' do
    with_console(script: [[:ping, 'hi'], [:text, 'after'], [:sleep, 0.3]]) do |console|
      assert_equal %w[after], read_messages(console)
      sleep 0.3

      pong = console.client_bytes.b
      assert_equal 0x8A, pong.getbyte(0), 'a pong frame'
      assert_predicate pong.getbyte(1) & 0x80, :positive?, 'client frames are masked'
      mask = pong.byteslice(2, 4).bytes
      assert_equal 'hi', pong.byteslice(6, 2).bytes.each_with_index.map { |b, i| b ^ mask[i % 4] }.pack('C*')
    end
  end

  test 'stops at the deadline when the server holds the connection open' do
    with_console(script: [[:text, 'only']], hold: true) do |console|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      assert_equal %w[only], read_messages(console, seconds: 1)
      assert_in_delta 1.0, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, 0.6
    end
  end

  test 'a bad API key raises an authentication error' do
    with_console(api_key: 'different') do |console|
      assert_raises(UnifiProtect::AuthError) { read_messages(console) }
    end
  end

  # --- DeviceNames ---

  test 'fetches device names across the device families and skips ones that fail' do
    cameras = [{ id: 'cam1', name: 'Front door' }, { id: 'cam2', name: 'Garage' }]
    with_console(cameras: cameras) do |console|
      names = UnifiProtect::DeviceNames.fetch(config(console), warn_io: StringIO.new)

      assert_equal({ 'cam1' => 'Front door', 'cam2' => 'Garage' }, names)
      assert_equal UnifiProtect::DEVICE_COLLECTIONS.size, console.paths.size
      assert_includes console.paths, '/proxy/protect/integration/v1/cameras'
    end
  end

  test 'a console that cannot be reached for names still yields an empty map with a warning' do
    unreachable = UnifiProtect::Config.new(host: '127.0.0.1:1', api_key: KEY, listen_seconds: 1, insecure: false,
                                           scheme: 'http')
    warnings = StringIO.new

    assert_empty UnifiProtect::DeviceNames.fetch(unreachable, warn_io: warnings)
    assert_match(/could not list cameras/, warnings.string)
  end

  test 'a rejected API key while listing devices is fatal rather than skipped' do
    with_console(api_key: 'different') do |console|
      assert_raises(UnifiProtect::AuthError) { UnifiProtect::DeviceNames.fetch(config(console), warn_io: StringIO.new) }
    end
  end

  # --- Runner ---

  test 'the runner prints one JSON line per event and skips everything else' do
    script = [[:text, event.to_json], [:text, 'garbage'],
              [:text, { type: 'update', item: { id: 'c', modelKey: 'camera' } }.to_json],
              [:text, event(type: 'ring', id: 'evt2', device: 'cam2').to_json]]
    cameras = [{ id: 'cam1', name: 'Front door' }, { id: 'cam2', name: 'Garage' }]
    with_console(cameras: cameras, script: script) do |console|
      out = StringIO.new
      err = StringIO.new

      status = UnifiProtect::Runner.new(config(console, listen_seconds: 1), out: out, err: err).call

      assert_equal 0, status
      lines = out.string.lines.map { |line| JSON.parse(line) }
      assert_equal ['Front door: motion started', 'Garage: ring started'], lines.pluck('message')
      assert_empty err.string
    end
  end

  test 'the runner fails with a message when the API key is rejected' do
    with_console(api_key: 'different') do |console|
      out = StringIO.new
      err = StringIO.new

      status = UnifiProtect::Runner.new(config(console, listen_seconds: 1), out: out, err: err).call

      assert_equal 1, status
      assert_empty out.string
      assert_match(/HTTP 401/, err.string)
    end
  end

  test 'the runner reports a console it cannot reach and exits non-zero' do
    unreachable = UnifiProtect::Config.new(host: '127.0.0.1:1', api_key: KEY, listen_seconds: 30, insecure: false,
                                           scheme: 'http')
    err = StringIO.new
    original = UnifiProtect::Runner::RETRY_DELAY
    UnifiProtect::Runner.send(:remove_const, :RETRY_DELAY)
    UnifiProtect::Runner.const_set(:RETRY_DELAY, 0)

    status = UnifiProtect::Runner.new(unreachable, out: StringIO.new, err: err).call

    assert_equal 1, status
    assert_match(/event stream kept failing/, err.string)
  ensure
    UnifiProtect::Runner.send(:remove_const, :RETRY_DELAY)
    UnifiProtect::Runner.const_set(:RETRY_DELAY, original)
  end

  # --- The program, as Member Zone runs it ---

  def script_env(console, extra = {})
    { 'UNIFI_HOST' => "127.0.0.1:#{console.port}", 'UNIFI_API_KEY' => KEY, 'UNIFI_SCHEME' => 'http',
      'UNIFI_LISTEN_SECONDS' => '1' }.merge(extra)
  end

  test 'the executable runs as a standalone program and prints parseable audit log lines' do
    with_console(cameras: [{ id: 'cam1', name: 'Front door' }], script: [[:text, event.to_json]]) do |console|
      stdout, stderr, status = Open3.capture3(script_env(console), SCRIPT)

      assert_predicate status, :success?, stderr
      assert_equal 'Front door: motion started', JSON.parse(stdout.lines.sole)['message']
    end
  end

  test 'the program exits 2 with a clear message when it is not configured' do
    _stdout, stderr, status = Open3.capture3({ 'UNIFI_HOST' => '', 'UNIFI_API_KEY' => '' }, SCRIPT)

    assert_equal 2, status.exitstatus
    assert_match(/UNIFI_HOST is not set/, stderr)
  end

  test 'the file is executable and starts with a Ruby shebang' do
    assert File.executable?(SCRIPT)
    assert_equal '#!/usr/bin/env ruby', File.foreach(SCRIPT).first.chomp
  end

  test 'Member Zone stores its events, encrypts the key, and does not store them twice' do
    script = [[:text, event.to_json], [:text, event(end: 1_790_679_960_000).merge(type: 'update').to_json]]
    with_console(cameras: [{ id: 'cam1', name: 'Front door' }], script: script) do |console|
      env = script_env(console).map { |key, value| "#{key}=#{value}" }.join("\n")
      source = AuditLogSource.create!(name: 'Unifi Protect', script_path: SCRIPT, environment_variables: env)

      run = AuditLogs::RunSource.call(source)

      assert_equal 'success', run.status, run.output
      assert_equal 2, run.entries_added
      assert_equal ['Front door: motion started', 'Front door: motion ended'],
                   source.audit_log_entries.order(:occurred_at).pluck(:message)
      stored = AuditLogSource.connection.select_value(
        "SELECT environment_variables FROM audit_log_sources WHERE id = #{source.id}"
      )
      assert_not_includes stored, KEY

      assert_equal 0, AuditLogs::RunSource.call(source.reload).entries_added, 'replayed events are de-duplicated'
    end
  end

  test 'a failing run is recorded as failed in Member Zone' do
    with_console(api_key: 'different') do |console|
      env = script_env(console).map { |key, value| "#{key}=#{value}" }.join("\n")
      source = AuditLogSource.create!(name: 'Unifi Protect', script_path: SCRIPT, environment_variables: env)

      run = AuditLogs::RunSource.call(source)

      assert_equal 'failed', run.status
      assert_equal 1, run.exit_code
      assert_match(/HTTP 401/, run.output)
    end
  end
end
