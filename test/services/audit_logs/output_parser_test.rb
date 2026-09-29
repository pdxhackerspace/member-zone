require 'test_helper'

module AuditLogs
  class OutputParserTest < ActiveSupport::TestCase
    RUN_AT = Time.zone.parse('2026-09-29 15:00:00')

    def parse(output)
      OutputParser.call(output, run_at: RUN_AT)
    end

    test 'parses a JSON line with timestamp, message and id' do
      entry = parse(%({"timestamp": "2026-09-29T10:00:00Z", "message": "door opened", "id": "e1", "door": 2}\n)).sole

      assert_equal Time.utc(2026, 9, 29, 10), entry[:occurred_at]
      assert_equal 'door opened', entry[:message]
      assert_equal 2, entry[:raw]['door']
      assert_equal 'e1', entry[:raw]['id']
    end

    test 'accepts the alternative key names' do
      entry = parse(%({"msg": "hi", "time": "2026-09-29T10:00:00Z"})).sole
      assert_equal 'hi', entry[:message]
      assert_equal Time.utc(2026, 9, 29, 10), entry[:occurred_at]

      stamped = parse(%({"message": "a", "@timestamp": "2026-09-29T10:00:00Z"})).sole
      assert_equal Time.utc(2026, 9, 29, 10), stamped[:occurred_at]
    end

    test 'accepts epoch seconds' do
      entry = parse(%({"message": "epoch", "ts": 1790679900})).sole
      assert_equal Time.at(1_790_679_900).utc, entry[:occurred_at].utc
    end

    test 'a JSON line without a timestamp, or with an unreadable one, is stamped with the run time' do
      assert_equal RUN_AT, parse(%({"message": "no time"})).sole[:occurred_at]
      assert_equal RUN_AT, parse(%({"message": "bad", "timestamp": "not a time"})).sole[:occurred_at]
    end

    test 'plain text lines are stored whole and stamped with the run time' do
      entries = parse("first\nsecond\n")

      assert_equal %w[first second], entries.pluck(:message)
      assert_equal [RUN_AT, RUN_AT], entries.pluck(:occurred_at)
      assert_equal [{}, {}], entries.pluck(:raw)
    end

    test 'blank lines are skipped and whitespace is trimmed' do
      assert_equal %w[a b], parse("\n  a  \n\n\t\nb\r\n").pluck(:message)
    end

    test 'a line that looks like JSON but is not, or has no message, is kept as plain text' do
      broken = '{"message": "unterminated'
      no_message = '{"other": 1}'

      entries = parse("#{broken}\n#{no_message}\n")
      assert_equal [broken, no_message], entries.pluck(:message)
      assert(entries.all? { |entry| entry[:raw] == {} })
    end

    test 'a JSON value that is not an object is plain text' do
      assert_equal ['[1, 2]'], parse("[1, 2]\n").pluck(:message)
    end

    test 'with an id, the fingerprint depends on the id alone' do
      first = parse(%({"message": "one", "id": "x", "timestamp": "2026-09-29T10:00:00Z"})).sole
      reworded = parse(%({"message": "two", "id": "x", "timestamp": "2026-09-29T11:00:00Z"})).sole
      other = parse(%({"message": "one", "id": "y", "timestamp": "2026-09-29T10:00:00Z"})).sole

      assert_equal first[:fingerprint], reworded[:fingerprint]
      assert_not_equal first[:fingerprint], other[:fingerprint]
    end

    test 'without an id, the fingerprint is stable across runs' do
      line = %({"message": "same", "timestamp": "2026-09-29T10:00:00Z"})

      assert_equal parse(line).sole[:fingerprint], OutputParser.call(line, run_at: 1.day.from_now).sole[:fingerprint]
    end

    test 'a plain line fingerprints the same whenever it is run' do
      assert_equal parse('same line').sole[:fingerprint],
                   OutputParser.call('same line', run_at: 1.year.from_now).sole[:fingerprint]
    end

    test 'identical lines within one run stay distinct' do
      fingerprints = parse("dup\ndup\ndup\n").pluck(:fingerprint)
      assert_equal 3, fingerprints.uniq.size
    end

    test 'the same repeated lines fingerprint identically on the next run' do
      assert_equal parse("dup\ndup\n").pluck(:fingerprint), parse("dup\ndup\n").pluck(:fingerprint)
    end

    test 'empty output gives no entries' do
      assert_empty parse('')
      assert_empty parse(nil)
    end
  end
end
