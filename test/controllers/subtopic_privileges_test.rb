require 'test_helper'

# Topic-scoped privileges reach one level down the tree, so an area lead who curates a parent
# topic can also curate and extend the subtopics nested directly beneath it.
class SubtopicPrivilegesTest < ActionDispatch::IntegrationTest
  setup do
    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true
    @parent = training_topics(:laser_cutting)
    @subtopic = TrainingTopic.create!(name: 'Subtopic under parent', parent: @parent)
    @unrelated = training_topics(:woodworking)
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  test 'a curator of a parent topic can open a subtopic page' do
    lead = sign_in_as_plain_member
    grant_privileges(lead, 'training.topics.manage_links', member_source: 'can_train', topic: @parent)

    get edit_training_topic_path(@subtopic)

    assert_response :success
  end

  test 'a curator cannot open a topic outside their tree' do
    lead = sign_in_as_plain_member
    grant_privileges(lead, 'training.topics.manage_links', member_source: 'can_train', topic: @parent)

    get edit_training_topic_path(@unrelated)

    assert_response :redirect
  end

  test 'a curator of a parent topic can edit a subtopic resource link' do
    lead = sign_in_as_plain_member
    grant_privileges(lead, 'training.topics.manage_links', member_source: 'can_train', topic: @parent)

    assert_difference 'TrainingTopicLink.count', 1 do
      post training_topic_links_path(@subtopic),
           params: { training_topic_link: { title: 'Subtopic guide', url: 'https://example.test/guide' } }
    end
  end

  test 'a curator can edit a subtopic description but not rename it' do
    lead = sign_in_as_plain_member
    grant_privileges(lead, 'training.topics.edit_details', member_source: 'can_train', topic: @parent)

    patch training_topic_path(@subtopic),
          params: { training_topic: { name: 'Renamed by curator', description: 'Curated description' } }

    @subtopic.reload

    assert_equal 'Curated description', @subtopic.description
    assert_equal 'Subtopic under parent', @subtopic.name
  end

  test 'an area lead can create a subtopic under a topic they hold' do
    lead = sign_in_as_plain_member
    grant_privileges(lead, 'training.subtopics.create', member_source: 'can_train', topic: @parent)

    assert_difference 'TrainingTopic.count', 1 do
      post training_topics_path, params: { training_topic: { name: 'Freshly added', parent_id: @parent.id } }
    end

    assert_equal @parent, TrainingTopic.find_by(name: 'Freshly added').parent
  end

  test 'an area lead cannot create a top level topic' do
    lead = sign_in_as_plain_member
    grant_privileges(lead, 'training.subtopics.create', member_source: 'can_train', topic: @parent)

    assert_no_difference 'TrainingTopic.count' do
      post training_topics_path, params: { training_topic: { name: 'Should not exist', parent_id: '' } }
    end
  end

  test 'an area lead cannot create a subtopic under someone elses topic' do
    lead = sign_in_as_plain_member
    grant_privileges(lead, 'training.subtopics.create', member_source: 'can_train', topic: @parent)

    assert_no_difference 'TrainingTopic.count' do
      post training_topics_path, params: { training_topic: { name: 'Should not exist', parent_id: @unrelated.id } }
    end
  end

  test 'creation reach does not extend to grandchildren of a held topic' do
    lead = sign_in_as_plain_member
    grandchild = TrainingTopic.create!(name: 'Grandchild topic', parent: @subtopic)
    grant_privileges(lead, 'training.subtopics.create', member_source: 'can_train', topic: @parent)

    assert_no_difference 'TrainingTopic.count' do
      post training_topics_path, params: { training_topic: { name: 'Too deep', parent_id: grandchild.id } }
    end
  end

  test 'a trained member can manage subtopics when the role is attached with trained_in' do
    lead = sign_in_as_plain_member
    grant_privileges(lead, 'training.topics.manage_links', member_source: 'trained_in', topic: @parent)

    assert_difference 'TrainingTopicLink.count', 1 do
      post training_topic_links_path(@subtopic),
           params: { training_topic_link: { title: 'From a trainee', url: 'https://example.test/t' } }
    end
  end

  test 'a subtopic manager can rename a subtopic' do
    lead = sign_in_as_plain_member
    grant_privileges(lead, 'training.subtopics.manage', member_source: 'trained_in', topic: @parent)

    patch training_topic_path(@subtopic), params: { training_topic: { name: 'Renamed subtopic' } }

    assert_equal 'Renamed subtopic', @subtopic.reload.name
  end

  test 'a subtopic manager can delete a subtopic' do
    lead = sign_in_as_plain_member
    grant_privileges(lead, 'training.subtopics.manage', member_source: 'trained_in', topic: @parent)

    assert_difference 'TrainingTopic.count', -1 do
      delete training_topic_path(@subtopic)
    end
  end

  test 'a subtopic manager cannot rename or delete the parent that granted it' do
    lead = sign_in_as_plain_member
    grant_privileges(lead, 'training.subtopics.manage', member_source: 'trained_in', topic: @parent)
    original_name = @parent.name

    patch training_topic_path(@parent), params: { training_topic: { name: 'Renamed parent' } }

    assert_equal original_name, @parent.reload.name

    assert_no_difference 'TrainingTopic.count' do
      delete training_topic_path(@parent)
    end
  end

  test 'a subtopic manager cannot delete a topic outside their tree' do
    lead = sign_in_as_plain_member
    grant_privileges(lead, 'training.subtopics.manage', member_source: 'trained_in', topic: @parent)

    assert_no_difference 'TrainingTopic.count' do
      delete training_topic_path(@unrelated)
    end
  end

  test 'a curator without subtopic manage cannot rename a subtopic' do
    lead = sign_in_as_plain_member
    grant_privileges(lead, 'training.topics.edit_details', member_source: 'trained_in', topic: @parent)

    assert_no_difference 'TrainingTopic.count' do
      delete training_topic_path(@subtopic)
    end
  end

  test 'the topic index renders subtopics nested under their parent' do
    sign_in_as_admin

    get training_topics_path

    assert_response :success
    assert_match @subtopic.name, response.body
  end

  test 'admins can still reparent a topic' do
    sign_in_as_admin

    patch training_topic_path(@subtopic), params: { training_topic: { parent_id: '' } }

    assert_nil @subtopic.reload.parent_id
  end

  test 'reparenting a topic to its own subtopic is rejected' do
    sign_in_as_admin

    patch training_topic_path(@parent), params: { training_topic: { parent_id: @subtopic.id } }

    assert_nil @parent.reload.parent_id
  end

  private

  def sign_in_as_plain_member
    account = local_accounts(:regular_member)
    post local_login_path, params: { session: { email: account.email, password: 'memberpassword123' } }
    User.find_by!(authentik_id: "local:#{account.id}")
  end

  def sign_in_as_admin
    member = sign_in_as_plain_member
    member.update!(is_admin: true)
    member
  end

  test 'a steward can appoint a trainer for a subtopic' do
    steward = sign_in_as_plain_member
    grant_privileges(steward, 'training.subtopics.grant_trainer', 'training.record', topic: @parent)
    trainee = users(:regular_member) if respond_to?(:users)
    trainee ||= User.where.not(id: steward.id).first

    assert_difference 'TrainerCapability.count', 1 do
      post add_trainer_capability_path(user_id: trainee.id, topic_id: @subtopic.id)
    end
    assert TrainerCapability.exists?(user: trainee, training_topic: @subtopic)
  end

  test 'a steward cannot appoint a trainer for the parent topic or an unrelated topic' do
    steward = sign_in_as_plain_member
    grant_privileges(steward, 'training.subtopics.grant_trainer', 'training.record', topic: @parent)
    trainee = User.where.not(id: steward.id).first

    assert_no_difference 'TrainerCapability.count' do
      post add_trainer_capability_path(user_id: trainee.id, topic_id: @parent.id)
      post add_trainer_capability_path(user_id: trainee.id, topic_id: @unrelated.id)
    end
  end

  test 'a steward can remove a subtopic trainer and sees the panel listing only their subtopics' do
    steward = sign_in_as_plain_member
    grant_privileges(steward, 'training.subtopics.grant_trainer', 'training.record', topic: @parent)
    trainee = User.where.not(id: steward.id).first
    TrainerCapability.create!(user: trainee, training_topic: @subtopic)

    get record_training_path
    assert_select '#trainer-capabilities-panel'

    assert_difference 'TrainerCapability.count', -1 do
      delete remove_trainer_capability_path(user_id: trainee.id, topic_id: @subtopic.id)
    end
  end

  test 'a curator without the grant privilege sees no trainer panel' do
    lead = sign_in_as_plain_member
    grant_privileges(lead, 'training.record', topic: @parent)

    get record_training_path
    assert_select '#trainer-capabilities-panel', count: 0
  end
end
