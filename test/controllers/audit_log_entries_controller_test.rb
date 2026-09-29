require 'test_helper'

class AuditLogEntriesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true

    @doors = create_audit_log_source(name: 'Doors')
    @wifi = create_audit_log_source(name: 'Wifi')
    @door_entry = create_audit_log_entry(@doors, message: 'Door 2 opened by fob', occurred_at: 2.hours.ago)
    @wifi_entry = create_audit_log_entry(@wifi, message: 'Guest network joined', occurred_at: 1.hour.ago)
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  def sign_in_reader(*privileges, topic: nil)
    member = sign_in_as_plain_member
    grant_privileges(member, *privileges, topic: topic)
    sign_in_as_plain_member
    member
  end

  # --- Access ---

  test 'a plain member is turned away' do
    sign_in_as_plain_member

    get audit_log_entries_path
    assert_response :redirect

    get audit_log_entry_path(@door_entry)
    assert_response :redirect
  end

  test 'signed-out visitors are sent to sign in' do
    get audit_log_entries_path
    assert_redirected_to login_path
  end

  test 'an administrator sees every source and entry' do
    sign_in_as_admin

    get audit_log_entries_path
    assert_response :success
    assert_select 'td', text: /Door 2 opened/
    assert_select 'td', text: /Guest network joined/
  end

  test 'view_all reads every source' do
    sign_in_reader('audit_logs.view_all')

    get audit_log_entries_path
    assert_response :success
    assert_select 'td', text: /Door 2 opened/
    assert_select 'td', text: /Guest network joined/
  end

  test 'a topic-scoped reader sees only their topic' do
    topic = TrainingTopic.create!(name: "Doors #{SecureRandom.hex(3)}")
    @doors.update!(training_topic: topic)
    sign_in_reader('audit_logs.view', topic: topic)

    get audit_log_entries_path
    assert_response :success
    assert_select 'td', text: /Door 2 opened/
    assert_select 'td', text: /Guest network joined/, count: 0
    assert_select '.filter-chip', text: /Wifi/, count: 0
    assert_select '.filter-chip', text: /Doors/
  end

  test 'a topic-scoped reader cannot open or explain an entry from another source' do
    topic = TrainingTopic.create!(name: "Doors #{SecureRandom.hex(3)}")
    @doors.update!(training_topic: topic)
    sign_in_reader('audit_logs.view', topic: topic)

    get audit_log_entry_path(@wifi_entry)
    assert_response :not_found

    patch explain_audit_log_entry_path(@wifi_entry), params: { audit_log_entry: { explanation: 'nope' } }
    assert_response :not_found
    assert_nil @wifi_entry.reload.explanation
  end

  test 'a topic-scoped reader cannot filter to a source they may not read' do
    topic = TrainingTopic.create!(name: "Doors #{SecureRandom.hex(3)}")
    @doors.update!(training_topic: topic)
    sign_in_reader('audit_logs.view', topic: topic)

    get audit_log_entries_path(source: @wifi.id)
    assert_response :success
    assert_select 'td', text: /Guest network joined/, count: 0
  end

  test 'alert and manage privileges alone do not grant reading' do
    sign_in_reader('audit_logs.alerts_all', 'audit_logs.alerts', 'audit_logs.manage')

    get audit_log_entries_path
    assert_response :redirect
  end

  test 'a source with no topic is invisible to topic-scoped readers' do
    topic = TrainingTopic.create!(name: "Doors #{SecureRandom.hex(3)}")
    sign_in_reader('audit_logs.view', topic: topic)

    get audit_log_entries_path
    assert_response :success
    assert_select 'td', text: /Door 2 opened/, count: 0
  end

  # --- Filters ---

  test 'a source pill narrows the list' do
    sign_in_as_admin

    get audit_log_entries_path(source: @doors.id)
    assert_select 'td', text: /Door 2 opened/
    assert_select 'td', text: /Guest network joined/, count: 0
    assert_select '.filter-chip.active', text: /Doors/
  end

  test 'there is a pill for each readable source with its count' do
    create_audit_log_entry(@doors, message: 'another door line')
    sign_in_as_admin

    get audit_log_entries_path
    assert_select '.filter-chip', text: /All sources\s*3/
    assert_select '.filter-chip', text: /Doors\s*2/
    assert_select '.filter-chip', text: /Wifi\s*1/
  end

  test 'the unexplained and alerted pills filter' do
    @door_entry.explain!('known', by: users(:one))
    @wifi_entry.update!(alerted_at: Time.current)
    sign_in_as_admin

    get audit_log_entries_path(state: 'unexplained')
    assert_select 'td', text: /Door 2 opened/, count: 0
    assert_select 'td', text: /Guest network joined/

    get audit_log_entries_path(state: 'alerted')
    assert_select 'td', text: /Guest network joined/
    assert_select 'td', text: /Door 2 opened/, count: 0
  end

  test 'an unknown state is ignored' do
    sign_in_as_admin

    get audit_log_entries_path(state: 'bogus')
    assert_response :success
    assert_select 'td', text: /Door 2 opened/
  end

  test 'text search matches the message' do
    sign_in_as_admin

    get audit_log_entries_path(q: 'GUEST network')
    assert_select 'td', text: /Guest network joined/
    assert_select 'td', text: /Door 2 opened/, count: 0
  end

  test 'search treats percent signs and underscores literally' do
    create_audit_log_entry(@doors, message: 'disk at 100% full')
    sign_in_as_admin

    get audit_log_entries_path(q: '100%')
    assert_select 'td', text: /disk at 100% full/
    assert_select 'td', text: /Door 2 opened/, count: 0
  end

  test 'a date range narrows the list' do
    old = create_audit_log_entry(@doors, message: 'ancient history', occurred_at: Time.zone.parse('2024-01-15 12:00'))
    sign_in_as_admin

    get audit_log_entries_path(from: '2024-01-15', to: '2024-01-15')
    assert_select 'td', text: /ancient history/
    assert_select 'td', text: /Door 2 opened/, count: 0

    get audit_log_entries_path(from: '2025-01-01')
    assert_select 'td', text: /ancient history/, count: 0
    assert_select 'td', text: /Door 2 opened/
    assert_predicate old, :persisted?
  end

  test 'an unparseable date is ignored rather than raising' do
    sign_in_as_admin

    get audit_log_entries_path(from: 'yesterday-ish', to: '2026-13-45')
    assert_response :success
    assert_select 'td', text: /Door 2 opened/
  end

  test 'filters combine' do
    create_audit_log_entry(@doors, message: 'Door 3 opened by fob', alerted_at: Time.current)
    sign_in_as_admin

    get audit_log_entries_path(source: @doors.id, state: 'alerted', q: 'fob')
    assert_select 'td', text: /Door 3 opened/
    assert_select 'td', text: /Door 2 opened/, count: 0
  end

  test 'shows an empty state, and says when filters are the reason' do
    sign_in_as_admin

    get audit_log_entries_path(q: 'no such text')
    assert_select '.card-body', text: /Nothing matches those filters/
    assert_select 'a', text: 'Clear filters'
  end

  test 'lists newest first' do
    sign_in_as_admin

    get audit_log_entries_path
    messages = css_select('tbody tr td:nth-child(4)').map { |cell| cell.text.strip }
    wifi_at = messages.index { |m| m.include?('Guest network') }
    doors_at = messages.index { |m| m.include?('Door 2') }
    assert_operator wifi_at, :<, doors_at
  end

  test 'marks alerted entries with a status dot' do
    @wifi_entry.update!(alerted_at: Time.current)
    sign_in_as_admin

    get audit_log_entries_path
    assert_select '.status-dot.status-danger', count: 1
  end

  test 'paginates' do
    Array.new(AuditLogEntriesController::PER_PAGE) { |i| create_audit_log_entry(@doors, message: "bulk #{i}") }
    sign_in_as_admin

    get audit_log_entries_path
    assert_select 'tbody tr', count: AuditLogEntriesController::PER_PAGE
    assert_select 'div', text: /Showing 1-50 of 52/

    get audit_log_entries_path(page: 2)
    assert_select 'tbody tr', count: 2
  end

  # --- Entry page and explanations ---

  test 'the entry page shows the message and the raw details' do
    entry = create_audit_log_entry(@doors, message: 'with details', raw: { 'door' => 7 })
    sign_in_as_admin

    get audit_log_entry_path(entry)
    assert_response :success
    assert_select 'pre', text: /with details/
    assert_select 'dt', text: 'door'
    assert_select 'dd', text: '7'
  end

  test 'a reader can explain an entry, and it records who and when' do
    reader = sign_in_reader('audit_logs.view_all')

    patch explain_audit_log_entry_path(@door_entry), params: { audit_log_entry: { explanation: 'Planned test' } }
    assert_redirected_to audit_log_entry_path(@door_entry)

    @door_entry.reload
    assert_equal 'Planned test', @door_entry.explanation
    assert_equal reader.id, @door_entry.explained_by_id
    assert_not_nil @door_entry.explained_at
  end

  test 'a topic-scoped reader can explain entries on their topic' do
    topic = TrainingTopic.create!(name: "Doors #{SecureRandom.hex(3)}")
    @doors.update!(training_topic: topic)
    sign_in_reader('audit_logs.view', topic: topic)

    patch explain_audit_log_entry_path(@door_entry), params: { audit_log_entry: { explanation: 'ok' } }
    assert_equal 'ok', @door_entry.reload.explanation
  end

  test 'explaining can be cleared' do
    @door_entry.explain!('temporary', by: users(:one))
    sign_in_as_admin

    patch explain_audit_log_entry_path(@door_entry), params: { audit_log_entry: { explanation: '' } }
    assert_nil @door_entry.reload.explanation
  end

  test 'a plain member cannot explain' do
    sign_in_as_plain_member

    patch explain_audit_log_entry_path(@door_entry), params: { audit_log_entry: { explanation: 'sneaky' } }
    assert_response :redirect
    assert_nil @door_entry.reload.explanation
  end

  test 'explaining cannot change the message' do
    sign_in_as_admin

    patch explain_audit_log_entry_path(@door_entry),
          params: { audit_log_entry: { explanation: 'x', message: 'rewritten', occurred_at: 1.year.ago } }

    assert_equal 'Door 2 opened by fob', @door_entry.reload.message
  end

  test 'there is no way to delete or edit an entry over HTTP' do
    sign_in_as_admin

    delete audit_log_entry_path(@door_entry)
    assert_response :not_found
    patch audit_log_entry_path(@door_entry), params: { audit_log_entry: { message: 'x' } }
    assert_response :not_found
    post audit_log_entries_path, params: { audit_log_entry: { message: 'x' } }
    assert_response :not_found
    assert_equal 'Door 2 opened by fob', @door_entry.reload.message
    assert AuditLogEntry.exists?(@door_entry.id)
  end

  # --- Impersonation ---

  test 'an administrator viewing as a plain member sees no audit log, and an explanation is attributed to the admin' do
    admin = sign_in_as_admin
    patch explain_audit_log_entry_path(@door_entry), params: { audit_log_entry: { explanation: 'as admin' } }
    assert_equal admin.id, @door_entry.reload.explained_by_id

    post impersonate_user_path(users(:one).id)
    get audit_log_entries_path
    assert_response :redirect, 'authorization follows the account being viewed as'

    patch explain_audit_log_entry_path(@door_entry), params: { audit_log_entry: { explanation: 'as member' } }
    assert_equal 'as admin', @door_entry.reload.explanation
  end

  test 'an administrator impersonating a reader is attributed as themselves' do
    admin = sign_in_as_admin
    reader = users(:one)
    grant_privileges(reader, 'audit_logs.view_all')

    post impersonate_user_path(reader.id)
    patch explain_audit_log_entry_path(@door_entry), params: { audit_log_entry: { explanation: 'viewing as reader' } }

    assert_equal admin.id, @door_entry.reload.explained_by_id
  end

  # --- Navigation ---

  test 'the Audit navbar entry appears for readers only, and Journal stays separate' do
    sign_in_as_plain_member
    get help_path
    assert_select '[data-nav-key="audit"]', count: 0

    member = sign_in_as_plain_member
    grant_privileges(member, 'audit_logs.view_all')
    sign_in_as_plain_member
    get help_path
    assert_select '[data-nav-key="audit"]', count: 1
    assert_select '[data-nav-key="journal"]', count: 0
  end

  test 'the Audit navbar entry appears for a topic-scoped reader' do
    topic = TrainingTopic.create!(name: "Doors #{SecureRandom.hex(3)}")
    sign_in_reader('audit_logs.view', topic: topic)

    get help_path
    assert_select '[data-nav-key="audit"]', count: 1
  end

  test 'journal.view reveals Journal without Audit' do
    sign_in_reader('journal.view')

    get help_path
    assert_select '[data-nav-key="journal"]', count: 1
    assert_select '[data-nav-key="audit"]', count: 0
  end
end
