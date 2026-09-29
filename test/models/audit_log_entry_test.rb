require 'test_helper'

class AuditLogEntryTest < ActiveSupport::TestCase
  setup do
    @source = create_audit_log_source
    @entry = create_audit_log_entry(@source, message: 'original text')
  end

  test 'destroy is refused' do
    assert_not @entry.destroy
    assert AuditLogEntry.exists?(@entry.id)
  end

  test 'destroy! raises rather than deleting' do
    assert_raises(ActiveRecord::RecordNotDestroyed) { @entry.destroy! }
    assert AuditLogEntry.exists?(@entry.id)
  end

  test 'delete is refused on the record' do
    assert_raises(AuditLogEntry::Immutable) { @entry.delete }
    assert AuditLogEntry.exists?(@entry.id)
  end

  test 'delete, delete_all and destroy_all are refused on the class' do
    assert_raises(AuditLogEntry::Immutable) { AuditLogEntry.delete(@entry.id) }
    assert_raises(AuditLogEntry::Immutable) { AuditLogEntry.delete_all }
    assert_raises(AuditLogEntry::Immutable) { AuditLogEntry.destroy_all }
    assert AuditLogEntry.exists?(@entry.id)
  end

  test 'removal is refused on any relation' do
    assert_raises(AuditLogEntry::Immutable) { AuditLogEntry.where(id: @entry.id).delete_all }
    assert_raises(AuditLogEntry::Immutable) { AuditLogEntry.where(id: @entry.id).destroy_all }
    assert_raises(AuditLogEntry::Immutable) { AuditLogEntry.where(id: @entry.id).delete_by(id: @entry.id) }
    assert_raises(AuditLogEntry::Immutable) { AuditLogEntry.where(id: @entry.id).destroy_by(id: @entry.id) }
    assert AuditLogEntry.exists?(@entry.id)
  end

  test 'removal is refused through the source association' do
    assert_raises(AuditLogEntry::Immutable) { @source.audit_log_entries.delete_all }
    assert_raises(AuditLogEntry::Immutable) { @source.audit_log_entries.destroy_all }
    assert_raises(AuditLogEntry::Immutable) { @source.audit_log_entries.where(id: @entry.id).delete_all }
    assert AuditLogEntry.exists?(@entry.id)
  end

  test 'the message, timestamp and fingerprint cannot be edited' do
    assert_not @entry.update(message: 'rewritten')
    assert_includes @entry.errors[:base].to_sentence, 'message'
    assert_equal 'original text', @entry.reload.message

    assert_not @entry.update(occurred_at: 1.year.ago)
    assert_not @entry.update(fingerprint: 'different')
    assert_not @entry.update(raw: { 'a' => 1 })
    assert_not @entry.update(audit_log_source: create_audit_log_source)
  end

  test 'the explanation and alert bookkeeping can change' do
    assert @entry.update(explanation: 'known maintenance', alerted_at: Time.current, matched_rule_ids: [1])
    assert_equal 'known maintenance', @entry.reload.explanation
  end

  test 'a fingerprint is unique within a source but may repeat across sources' do
    duplicate = @source.audit_log_entries.build(message: 'x', occurred_at: Time.current,
                                                fingerprint: @entry.fingerprint)
    assert_not duplicate.valid?

    other = create_audit_log_source
    assert other.audit_log_entries.build(message: 'x', occurred_at: Time.current,
                                         fingerprint: @entry.fingerprint).valid?
  end

  test 'explain! records who wrote it and when' do
    author = users(:one)
    @entry.explain!('  Planned door test  ', by: author)

    @entry.reload
    assert_equal 'Planned door test', @entry.explanation
    assert_equal author, @entry.explained_by
    assert_in_delta Time.current, @entry.explained_at, 5.seconds
    assert @entry.explained?
  end

  test 'a blank explanation clears the attribution' do
    @entry.explain!('note', by: users(:one))
    @entry.explain!('   ', by: users(:two))

    @entry.reload
    assert_nil @entry.explanation
    assert_nil @entry.explained_by
    assert_nil @entry.explained_at
    assert_not @entry.explained?
  end

  test 'deleting the user who explained an entry keeps the entry' do
    author = User.create!(email: "author-#{SecureRandom.hex(3)}@example.com", full_name: 'Author',
                          authentik_id: "a-#{SecureRandom.hex(4)}", username: "author#{SecureRandom.hex(3)}")
    @entry.explain!('note', by: author)

    author.destroy!
    assert_nil @entry.reload.explained_by_id
    assert_equal 'note', @entry.explanation
  end

  test 'matching searches the message case-insensitively and treats wildcards literally' do
    create_audit_log_entry(@source, message: 'Failed login for root')
    create_audit_log_entry(@source, message: '100% disk usage')

    assert_equal ['Failed login for root'], AuditLogEntry.matching('FAILED LOGIN').pluck(:message)
    assert_equal ['100% disk usage'], AuditLogEntry.matching('100%').pluck(:message)
    assert_equal ['100% disk usage'], AuditLogEntry.matching('%').pluck(:message)
  end

  test 'scopes split explained from unexplained and alerted from quiet' do
    explained = create_audit_log_entry(@source, explanation: 'done')
    alerted = create_audit_log_entry(@source, alerted_at: Time.current)

    assert_includes AuditLogEntry.unexplained, @entry
    assert_not_includes AuditLogEntry.unexplained, explained
    assert_equal [alerted], AuditLogEntry.alerted.to_a
  end

  test 'newest_first orders by occurrence time' do
    old = create_audit_log_entry(@source, occurred_at: 3.days.ago)
    recent = create_audit_log_entry(@source, occurred_at: 1.minute.from_now)

    ordered = AuditLogEntry.newest_first.to_a
    assert_equal recent, ordered.first
    assert_equal old, ordered.last
  end
end
