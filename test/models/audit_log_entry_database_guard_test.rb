require 'test_helper'

# The model refuses edits and deletes, but anything that skips it — update_all, raw SQL, a
# console session — would not notice. These pin the trigger that stops those too.
class AuditLogEntryDatabaseGuardTest < ActiveSupport::TestCase
  setup do
    @source = create_audit_log_source
    @entry = create_audit_log_entry(@source, message: 'original', raw: { 'k' => 1 })
  end

  # A failed statement poisons the surrounding transaction, so each attempt gets a savepoint.
  def refused(&)
    error = assert_raises(ActiveRecord::StatementInvalid) do
      AuditLogEntry.transaction(requires_new: true, &)
    end
    error.message
  end

  test 'a row cannot be deleted with SQL' do
    message = refused { AuditLogEntry.connection.execute("DELETE FROM audit_log_entries WHERE id = #{@entry.id}") }
    assert_match(/cannot be deleted/, message)
    assert AuditLogEntry.exists?(@entry.id)
  end

  test 'the table cannot be truncated' do
    assert_match(/cannot be deleted/, refused { AuditLogEntry.connection.execute('TRUNCATE audit_log_entries') })
    assert AuditLogEntry.exists?(@entry.id)
  end

  test 'update_all cannot touch the record itself' do
    %i[message fingerprint occurred_at raw audit_log_source_id created_at].each do |column|
      value = { message: 'x', fingerprint: 'y', occurred_at: 1.year.ago, raw: { 'z' => 2 },
                audit_log_source_id: create_audit_log_source.id, created_at: 1.year.ago }.fetch(column)

      assert_match(/cannot be edited/, refused { AuditLogEntry.where(id: @entry.id).update_all(column => value) },
                   "#{column} should be locked")
    end

    @entry.reload
    assert_equal 'original', @entry.message
    assert_equal({ 'k' => 1 }, @entry.raw)
  end

  test 'update_columns and raw SQL are stopped too' do
    assert_match(/cannot be edited/, refused { @entry.update_columns(message: 'sneaky') })
    assert_match(/cannot be edited/, refused do
      AuditLogEntry.connection.execute("UPDATE audit_log_entries SET message = 'sneaky' WHERE id = #{@entry.id}")
    end)
    assert_equal 'original', @entry.reload.message
  end

  test 'the explanation and alert columns can still be written past the model' do
    AuditLogEntry.where(id: @entry.id).update_all(explanation: 'note', alerted_at: Time.current, matched_rule_ids: [1],
                                                  explained_at: Time.current, updated_at: Time.current)

    assert_equal 'note', @entry.reload.explanation
    assert_predicate @entry, :alerted?
  end

  test 'setting a locked column to the value it already has is not an edit' do
    assert_nothing_raised do
      AuditLogEntry.where(id: @entry.id).update_all(message: 'original', explanation: 'fine')
    end
  end

  test 'deleting the user who explained an entry still works, nulling only explained_by' do
    author = User.create!(email: "g-#{SecureRandom.hex(3)}@example.com", full_name: 'Guard Author',
                          authentik_id: "g-#{SecureRandom.hex(4)}", username: "guard#{SecureRandom.hex(3)}")
    @entry.explain!('note', by: author)

    author.destroy!

    assert_nil @entry.reload.explained_by_id
    assert_equal 'note', @entry.explanation
  end

  test 'a source with entries still cannot be deleted' do
    assert_raises(ActiveRecord::InvalidForeignKey) do
      AuditLogEntry.transaction(requires_new: true) do
        AuditLogEntry.connection.execute("DELETE FROM audit_log_sources WHERE id = #{@source.id}")
      end
    end
  end

  test 'db/schema.rb carries the guard so a schema load recreates it' do
    assert_includes Rails.root.join('db/schema.rb').read, AuditLogEntryGuard.schema_statement
  end

  test 'a dump of the live database includes the guard' do
    io = StringIO.new
    ActiveRecord::SchemaDumper.dump(AuditLogEntry.connection_pool, io)

    assert_includes io.string, 'audit_log_entries_guard'
  end
end
