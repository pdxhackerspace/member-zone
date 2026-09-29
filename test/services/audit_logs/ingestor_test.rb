require 'test_helper'

module AuditLogs
  class IngestorTest < ActiveSupport::TestCase
    setup { @source = create_audit_log_source }

    def entry(message, fingerprint: message, raw: {})
      { occurred_at: Time.zone.parse('2026-09-29 10:00'), message: message, raw: raw, fingerprint: fingerprint }
    end

    test 'stores entries and returns them' do
      stored = Ingestor.call(@source, [entry('a', raw: { 'k' => 1 }), entry('b')])

      assert_equal %w[a b], stored.pluck(:message).sort
      assert_equal 2, @source.audit_log_entries.count
      assert_equal({ 'k' => 1 }, @source.audit_log_entries.find_by!(message: 'a').raw)
    end

    test 'skips entries the source already has and returns only the new ones' do
      Ingestor.call(@source, [entry('a')])

      stored = Ingestor.call(@source, [entry('a'), entry('b')])

      assert_equal ['b'], stored.pluck(:message)
      assert_equal 2, @source.audit_log_entries.count
    end

    test 'the same fingerprint in another source is a different entry' do
      other = create_audit_log_source
      Ingestor.call(@source, [entry('a')])

      assert_equal 1, Ingestor.call(other, [entry('a')]).count
    end

    test 'an already-stored entry keeps its explanation when re-ingested' do
      Ingestor.call(@source, [entry('a')])
      @source.audit_log_entries.sole.explain!('note', by: users(:one))

      Ingestor.call(@source, [entry('a')])

      assert_equal 'note', @source.audit_log_entries.sole.explanation
    end

    test 'nothing to store returns an empty result' do
      assert_empty Ingestor.call(@source, [])
    end

    test 'handles more entries than one batch' do
      entries = Array.new(Ingestor::BATCH_SIZE + 5) { |i| entry("line #{i}") }

      assert_equal Ingestor::BATCH_SIZE + 5, Ingestor.call(@source, entries).count
    end
  end
end
