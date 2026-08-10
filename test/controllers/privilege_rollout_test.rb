require 'test_helper'

# Areas converted from require_admin! to privilege gates: key fobs, membership plans,
# topic resource links, and topic documents.
class PrivilegeRolloutTest < ActionDispatch::IntegrationTest
  setup do
    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true
    @topic = training_topics(:laser_cutting)
    @other_topic = training_topics(:woodworking)
    @member = users(:one)
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  # ─── Key fobs ─────────────────────────────────────────────────────────

  test 'a key fob manager can open the add fob form' do
    staff = sign_in_as_plain_member
    grant_privileges(staff, 'access.manage_rfids')

    get new_rfid_path

    assert_response :success
  end

  test 'a member without the fob privilege cannot open the add fob form' do
    sign_in_as_plain_member

    get new_rfid_path

    assert_response :redirect
  end

  test 'a key fob manager can add a fob' do
    staff = sign_in_as_plain_member
    grant_privileges(staff, 'access.manage_rfids')

    assert_difference 'Rfid.count', 1 do
      post rfids_path, params: { rfid: { user_id: @member.id, rfid: 'ROLLOUT001' } }
    end
  end

  test 'a key fob manager cannot use the fob form to confer training privileges' do
    staff = sign_in_as_plain_member
    grant_privileges(staff, 'access.manage_rfids')
    building_access = training_topics(:building_access)
    role = Role.create!(name: 'Fob granter', privileges: [find_or_create_privilege('members.ban')])
    TrainingTopicRole.create!(training_topic: building_access, role: role, member_source: 'trained_in')

    assert_no_difference 'Training.count' do
      post rfids_path, params: { rfid: { user_id: @member.id, rfid: 'ROLLOUT002' }, add_training: '1' }
    end
  end

  test 'access.pause_resume allows pausing key access' do
    staff = sign_in_as_plain_member
    grant_privileges(staff, 'access.pause_resume')

    post pause_key_access_user_path(@member)

    assert_predicate @member.reload, :key_access_paused?
  end

  test 'pausing key access is refused without the privilege' do
    sign_in_as_plain_member

    post pause_key_access_user_path(@member)

    assert_not_predicate @member.reload, :key_access_paused?
  end

  # ─── Membership plans ─────────────────────────────────────────────────

  test 'plans.manage opens the plans index' do
    staff = sign_in_as_plain_member
    grant_privileges(staff, 'plans.manage')

    get membership_plans_path

    assert_response :success
  end

  test 'the plans index is refused without plans.manage' do
    sign_in_as_plain_member

    get membership_plans_path

    assert_response :redirect
  end

  test 'plans.manual_payments opens the manual payments page' do
    staff = sign_in_as_plain_member
    grant_privileges(staff, 'plans.manual_payments')

    get manual_payments_membership_plans_path

    assert_response :success
  end

  test 'manual payments is refused without the privilege' do
    sign_in_as_plain_member

    get manual_payments_membership_plans_path

    assert_response :redirect
  end

  test 'plans.view_hidden reveals hidden plans on the plan page' do
    staff = sign_in_as_plain_member
    grant_privileges(staff, 'plans.view_hidden')
    hidden = membership_plans(:personal_equipment_donation)
    hidden.update!(plan_type: 'primary', user: nil, visible: false)

    get membership_plan_path(membership_plans(:monthly_standard))

    assert_response :success
    assert_match hidden.name, response.body
  end

  test 'hidden plans stay hidden without plans.view_hidden' do
    sign_in_as_plain_member
    hidden = membership_plans(:personal_equipment_donation)
    hidden.update!(plan_type: 'primary', user: nil, visible: false)

    get membership_plan_path(membership_plans(:monthly_standard))

    assert_response :success
    assert_no_match(/#{hidden.name}/, response.body)
  end

  test 'a hidden plan cannot be opened by id without plans.view_hidden' do
    sign_in_as_plain_member
    hidden = membership_plans(:monthly_standard)
    hidden.update!(visible: false)

    get membership_plan_path(hidden)

    assert_response :redirect
  end

  test 'plans.view_hidden opens a hidden plan by id' do
    staff = sign_in_as_plain_member
    grant_privileges(staff, 'plans.view_hidden')
    hidden = membership_plans(:monthly_standard)
    hidden.update!(visible: false)

    get membership_plan_path(hidden)

    assert_response :success
  end

  test 'a member can open a hidden plan they are on' do
    member = sign_in_as_plain_member
    hidden = membership_plans(:monthly_standard)
    hidden.update!(visible: false)
    member.update!(membership_plan: hidden)

    get membership_plan_path(hidden)

    assert_response :success
  end

  test 'a member can open their own personal plan' do
    member = sign_in_as_plain_member
    personal = membership_plans(:personal_equipment_donation)
    personal.update!(user: member)

    get membership_plan_path(personal)

    assert_response :success
  end

  test "a member cannot open another member's personal plan" do
    sign_in_as_plain_member
    personal = membership_plans(:personal_equipment_donation)
    personal.update!(user: @member)

    get membership_plan_path(personal)

    assert_response :redirect
  end

  # ─── Topic resources ──────────────────────────────────────────────────

  test 'a curator can add a link to the topic they curate' do
    curator = sign_in_as_plain_member
    grant_privileges(curator, 'training.topics.manage_links', member_source: 'can_train', topic: @topic)

    assert_difference 'TrainingTopicLink.count', 1 do
      post training_topic_links_path(@topic),
           params: { training_topic_link: { title: 'Safety guide', url: 'https://example.com/safety' } }
    end
  end

  test 'a curator cannot add a link to a topic they do not curate' do
    curator = sign_in_as_plain_member
    grant_privileges(curator, 'training.topics.manage_links', member_source: 'can_train', topic: @topic)

    assert_no_difference 'TrainingTopicLink.count' do
      post training_topic_links_path(@other_topic),
           params: { training_topic_link: { title: 'Sneaky', url: 'https://example.com/sneaky' } }
    end
  end

  test 'a curator reaches the topic page for their topic only' do
    curator = sign_in_as_plain_member
    grant_privileges(curator, 'training.topics.manage_links', member_source: 'can_train', topic: @topic)

    get edit_training_topic_path(@topic)

    assert_response :success

    get edit_training_topic_path(@other_topic)

    assert_response :redirect
  end

  test 'a curator cannot rename the topic they curate' do
    curator = sign_in_as_plain_member
    grant_privileges(curator, 'training.topics.manage_links', member_source: 'can_train', topic: @topic)

    patch training_topic_path(@topic), params: { training_topic: { name: 'Renamed by curator' } }

    assert_equal 'Laser Cutting', @topic.reload.name
  end

  test 'training.topics.manage opens the topics index' do
    staff = sign_in_as_plain_member
    grant_privileges(staff, 'training.topics.manage')

    get training_topics_path

    assert_response :success
  end

  test 'a curator can attach a document to the topic they curate' do
    curator = sign_in_as_plain_member
    grant_privileges(curator, 'training.documents.manage', member_source: 'can_train', topic: @topic)

    get new_document_path(training_topic_id: @topic.id)

    assert_response :success
    assert_match 'Laser Cutting', response.body
    assert_no_match(/Woodworking/, response.body)
  end

  test 'training.revoke is required to revoke training' do
    staff = sign_in_as_plain_member
    grant_privileges(staff, 'training.topics.manage')
    Training.create!(trainee: @member, training_topic: @topic, trained_at: 1.day.ago)

    assert_no_difference 'Training.count' do
      delete revoke_training_training_topic_path(@topic, user_id: @member.id)
    end
  end

  test 'a topic revoker with the privilege can revoke training' do
    staff = sign_in_as_plain_member
    grant_privileges(staff, 'training.topics.manage', 'training.revoke', member_source: 'trained_in', topic: @topic)
    Training.create!(trainee: @member, training_topic: @topic, trained_at: 1.day.ago)

    assert_difference 'Training.count', -1 do
      delete revoke_training_training_topic_path(@topic, user_id: @member.id)
    end
  end

  test 'training.record does not carry the power to remove training' do
    trainer = sign_in_as_plain_member
    grant_privileges(trainer, 'training.record', member_source: 'trained_in', topic: @topic)
    Training.create!(trainee: @member, training_topic: @topic, trained_at: 1.day.ago)

    assert_no_difference 'Training.count' do
      delete remove_training_path(user_id: @member.id, topic_id: @topic.id)
    end
  end

  test 'a trainer holding training.revoke can remove training' do
    trainer = sign_in_as_plain_member
    grant_privileges(trainer, 'training.record', 'training.revoke', member_source: 'trained_in', topic: @topic)
    Training.create!(trainee: @member, training_topic: @topic, trained_at: 1.day.ago)

    assert_difference 'Training.count', -1 do
      delete remove_training_path(user_id: @member.id, topic_id: @topic.id)
    end
  end

  test 'trainer capability alone does not carry the power to remove training' do
    trainer = sign_in_as_plain_member
    TrainerCapability.create!(user: trainer, training_topic: @topic)
    Training.create!(trainee: @member, training_topic: @topic, trained_at: 1.day.ago)

    assert_no_difference 'Training.count' do
      delete remove_training_path(user_id: @member.id, topic_id: @topic.id)
    end
  end

  private

  def sign_in_as_plain_member
    account = local_accounts(:regular_member)
    post local_login_path, params: { session: { email: account.email, password: 'memberpassword123' } }
    User.find_by!(authentik_id: "local:#{account.id}")
  end
end
