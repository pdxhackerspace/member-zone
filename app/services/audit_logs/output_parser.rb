require 'digest'

module AuditLogs
  # Turns what a program printed to stdout into entry attributes.
  #
  # Preferred: one JSON object per line, {"timestamp": "...", "message": "...", "id": "..."}.
  # `timestamp` (also `time`, `ts`, `@timestamp`) may be ISO8601 or epoch seconds; `message`
  # (also `msg`) is the text; `id` is an optional identifier that makes de-duplication exact.
  # Every key is kept in `raw`. Any other non-blank line is taken as plain text and stamped
  # with the time of the run.
  #
  # An entry's fingerprint decides whether it has been seen before. Without an id it is a
  # hash of the timestamp and text — or of the text alone for plain lines, which carry no
  # timestamp of their own, so a program that re-prints its whole log does not duplicate it.
  # Identical lines within one run are kept apart by an occurrence count.
  class OutputParser
    TIMESTAMP_KEYS = %w[timestamp time ts @timestamp].freeze
    MESSAGE_KEYS = %w[message msg].freeze

    def self.call(output, run_at: Time.current)
      new(output, run_at).call
    end

    def initialize(output, run_at)
      @output = output.to_s
      @run_at = run_at
      @seen = Hash.new(0)
    end

    def call
      @output.each_line.filter_map { |line| parse_line(line.strip) }
    end

    private

    def parse_line(line)
      return if line.empty?

      json = parse_json(line)
      json ? structured_entry(json) : plain_entry(line)
    end

    def parse_json(line)
      return unless line.start_with?('{')

      parsed = JSON.parse(line)
      parsed if parsed.is_a?(Hash) && message_from(parsed).present?
    rescue JSON::ParserError
      nil
    end

    def structured_entry(json)
      message = message_from(json)
      time = time_from(json)
      basis = json['id'].present? ? "id:#{json['id']}" : "#{time.utc.iso8601(6)}|#{message}"

      { occurred_at: time, message: message, raw: json, fingerprint: fingerprint(basis, exact: json['id'].present?) }
    end

    def plain_entry(line)
      { occurred_at: @run_at, message: line, raw: {}, fingerprint: fingerprint("text|#{line}") }
    end

    def message_from(json)
      MESSAGE_KEYS.filter_map { |key| json[key] }.first.to_s.strip
    end

    def time_from(json)
      value = TIMESTAMP_KEYS.filter_map { |key| json[key] }.first
      parse_time(value) || @run_at
    end

    def parse_time(value)
      case value
      when Numeric then Time.zone.at(value)
      when String then Time.zone.parse(value)
      end
    rescue ArgumentError, RangeError
      nil
    end

    # An explicit id is trusted to be unique; anything else is disambiguated by how many
    # times the same basis has already appeared in this run.
    def fingerprint(basis, exact: false)
      return Digest::SHA256.hexdigest(basis) if exact

      @seen[basis] += 1
      Digest::SHA256.hexdigest("#{basis}##{@seen[basis]}")
    end
  end
end
