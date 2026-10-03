require 'test_helper'

# Member-facing surfaces, where a privilege works the other way round.
#
# On an admin page a privilege is what lets you in. Here access already flows from a data
# relationship — you are trained in the topic, you are on the plan, the notice is yours —
# and the privilege only ever adds to that. Every check in this file is written with `||`
# for that reason: an `&&` would take a member's own training documents away from them.
#
# Each test therefore asserts both directions: the holder gains something, and the plain
# member keeps everything they had.
class PrivilegeRolloutPhase7Test < ActionDispatch::IntegrationTest
  setup do
    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  # ─── The training catalogue ───────────────────────────────────────────

  test 'training.catalog.view_all adds the topics not on offer' do
    hidden = TrainingTopic.create!(name: 'Phase 7 Hidden Topic', offered_to_members: false)

    sign_in_as_plain_member
    get training_catalog_path
    assert_select 'body' do
      assert_no_match(/Phase 7 Hidden Topic/, response.body)
    end

    holder('training.catalog.view_all')
    get training_catalog_path
    assert_match(/Phase 7 Hidden Topic/, response.body)

    get training_catalog_topic_path(hidden)
    assert_response :success
  end

  test 'a topic not on offer stays closed without the privilege' do
    hidden = TrainingTopic.create!(name: 'Phase 7 Closed Topic', offered_to_members: false)
    sign_in_as_plain_member

    get training_catalog_topic_path(hidden)

    assert_response :redirect
  end

  # The privilege must not become the only way in: the topics on offer are every member's
  # regardless, which is the failure mode of writing && instead of ||.
  test 'a plain member still sees the topics on offer' do
    offered = TrainingTopic.create!(name: 'Phase 7 Offered Topic', offered_to_members: true)
    sign_in_as_plain_member

    get training_catalog_path

    assert_match(/Phase 7 Offered Topic/, response.body)
    get training_catalog_topic_path(offered)
    assert_response :success
  end

  # ─── Documents ────────────────────────────────────────────────────────

  test 'training.documents.view_all opens a document the member has no training for' do
    document = phase7_document

    sign_in_as_plain_member
    get download_document_path(document)
    assert_response :redirect

    holder('training.documents.view_all')
    get download_document_path(document)
    assert_response :success
  end

  test 'a member keeps the documents their own training entitles them to' do
    document = phase7_document
    member = sign_in_as_plain_member
    Training.create!(trainee: member, training_topic: document.training_topics.first,
                     trained_at: Time.current)
    sign_in_as_plain_member

    get download_document_path(document)

    assert_response :success
  end

  # ─── Parking clearance ────────────────────────────────────────────────

  test 'a member clears their own notice without any privilege' do
    member = sign_in_as_plain_member
    notice = phase7_notice(member, requires_admin_clearance: false)

    assert notice.clearable_by?(member)
  end

  test 'parking.clear_admin_required is what clears a notice held for staff' do
    member = users(:one)
    notice = phase7_notice(member, requires_admin_clearance: true)

    assert_not notice.clearable_by?(member), 'the flag exists to hold the notice open'

    grant_privileges(member, 'parking.clear_admin_required')
    assert notice.clearable_by?(User.find(member.id))
  end

  test 'parking.manage_notices clears an ordinary notice but not one held for staff' do
    owner = users(:one)
    staff = users(:two)
    grant_privileges(staff, 'parking.manage_notices')
    staff = User.find(staff.id)

    assert notice_clearable?(phase7_notice(owner, requires_admin_clearance: false), staff)
    assert_not notice_clearable?(phase7_notice(owner, requires_admin_clearance: true), staff)
  end

  test 'the clear action refuses a notice held for staff' do
    owner = users(:one)
    notice = phase7_notice(owner, requires_admin_clearance: true)
    holder('parking.manage_notices')

    post clear_parking_notice_path(notice)

    assert_equal 'That notice needs staff clearance.', flash[:alert]
    assert_not_predicate notice.reload, :cleared?
  end

  test 'parking.clear_admin_required clears it through the same action' do
    owner = users(:one)
    notice = phase7_notice(owner, requires_admin_clearance: true)
    holder('parking.manage_notices', 'parking.clear_admin_required')

    post clear_parking_notice_path(notice)

    assert_predicate notice.reload, :cleared?
  end

  # ─── Search ───────────────────────────────────────────────────────────

  # A member's search covers the roster they can already browse. search.admin adds the
  # source records behind it — Authentik, Slack, the sheet — which is where the addresses
  # and identity ids live.
  test 'search.admin widens search to the source records' do
    SlackUser.create!(slack_id: 'PHASE7SLACK', display_name: 'Phase 7 Slacker')

    sign_in_as_plain_member
    get search_path(q: 'phase 7')
    assert_no_match(/Slack Users/, response.body)

    holder('search.admin')
    get search_path(q: 'phase 7')

    assert_response :success
    assert_match(/Slack Users/, response.body)
  end

  private

  def notice_clearable?(notice, actor)
    notice.clearable_by?(actor)
  end

  def phase7_notice(owner, requires_admin_clearance:)
    create_parking_notice!(
      user: owner, issued_by: users(:two), notice_type: 'ticket', status: 'active',
      description: 'Phase 7 notice', location: 'Lot', expires_at: 1.day.from_now,
      requires_admin_clearance: requires_admin_clearance
    )
  end

  def phase7_document
    @phase7_document ||= begin
      topic = TrainingTopic.create!(name: 'Phase 7 Document Topic', offered_to_members: true)
      document = Document.create!(title: 'Phase 7 Document', show_on_all_profiles: false,
                                  file: fixture_file_upload('test_document.txt', 'text/plain'))
      document.training_topics << topic
      document
    end
  end

  def holder(*privilege_keys)
    member = sign_in_as_plain_member
    privilege_keys.each { |key| grant_privileges(member, key) }
    sign_in_as_plain_member
  end
end
