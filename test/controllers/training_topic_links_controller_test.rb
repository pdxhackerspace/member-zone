require 'test_helper'

class TrainingTopicLinksControllerTest < ActionDispatch::IntegrationTest
  setup do
    @laser_topic = training_topics(:laser_cutting)
    @woodworking_topic = training_topics(:woodworking)
    @laser_link = training_topic_links(:laser_safety_guide)
    @woodworking_link = training_topic_links(:woodworking_manual)
  end

  # ─── Helper methods ───────────────────────────────────────────────────

  def sign_in_as_admin
    Rails.application.config.x.local_auth.enabled = true
    post local_login_path, params: {
      session: { email: 'admin@example.com', password: 'localpassword123' }
    }
  end

  def sign_in_as_trainer
    Rails.application.config.x.local_auth.enabled = true
    post local_login_path, params: {
      session: { email: 'trainer@example.com', password: 'trainerpassword123' }
    }
    user = User.find_by('authentik_id LIKE ?', "local:#{local_accounts(:trainer_account).id}")
    TrainerCapability.find_or_create_by!(user: user, training_topic: @laser_topic)
    user
  end

  def sign_in_as_regular_member
    Rails.application.config.x.local_auth.enabled = true
    post local_login_path, params: {
      session: { email: 'member@example.com', password: 'memberpassword123' }
    }
  end

  # ─── Not signed in ────────────────────────────────────────────────────

  test 'unauthenticated user cannot create a link' do
    assert_no_difference 'TrainingTopicLink.count' do
      post training_topic_links_path(@laser_topic), params: {
        training_topic_link: { title: 'New Link', url: 'https://example.com' }
      }
    end
    assert_redirected_to login_path
  end

  # ─── Admin access ─────────────────────────────────────────────────────

  test 'admin can create a link for any topic' do
    sign_in_as_admin

    assert_difference 'TrainingTopicLink.count', 1 do
      post training_topic_links_path(@laser_topic), params: {
        training_topic_link: { title: 'New Safety Doc', url: 'https://example.com/safety' }
      }
    end
    assert_redirected_to edit_training_topic_path(@laser_topic)

    assert_difference 'TrainingTopicLink.count', 1 do
      post training_topic_links_path(@woodworking_topic), params: {
        training_topic_link: { title: 'Wood Guide', url: 'https://example.com/wood' }
      }
    end
    assert_redirected_to edit_training_topic_path(@woodworking_topic)
  end

  test 'admin can update a link' do
    sign_in_as_admin
    patch training_topic_link_path(@laser_topic, @laser_link), params: {
      training_topic_link: { title: 'Updated Laser Guide' }
    }
    assert_redirected_to edit_training_topic_path(@laser_topic)
    @laser_link.reload
    assert_equal 'Updated Laser Guide', @laser_link.title
  end

  test 'admin can delete a link' do
    sign_in_as_admin
    assert_difference 'TrainingTopicLink.count', -1 do
      delete training_topic_link_path(@laser_topic, @laser_link)
    end
    assert_redirected_to edit_training_topic_path(@laser_topic)
  end

  # ─── Trainer access ───────────────────────────────────────────────────

  test 'trainer cannot create a link for their topic' do
    sign_in_as_trainer
    assert_no_difference 'TrainingTopicLink.count' do
      post training_topic_links_path(@laser_topic), params: {
        training_topic_link: { title: 'Trainer Link', url: 'https://example.com/trainer' }
      }
    end
    assert_response :redirect
  end

  test 'trainer cannot create a link for a topic they do not train' do
    sign_in_as_trainer
    assert_no_difference 'TrainingTopicLink.count' do
      post training_topic_links_path(@woodworking_topic), params: {
        training_topic_link: { title: 'Unauthorized', url: 'https://example.com/nope' }
      }
    end
    assert_response :redirect
  end

  test 'trainer cannot update a link for their topic' do
    sign_in_as_trainer
    original_title = @laser_link.title
    patch training_topic_link_path(@laser_topic, @laser_link), params: {
      training_topic_link: { title: 'Trainer Updated Title' }
    }
    assert_response :redirect
    @laser_link.reload
    assert_equal original_title, @laser_link.title
  end

  test 'trainer cannot update a link for a topic they do not train' do
    sign_in_as_trainer
    original_title = @woodworking_link.title
    patch training_topic_link_path(@woodworking_topic, @woodworking_link), params: {
      training_topic_link: { title: 'Hacked Title' }
    }
    assert_response :redirect
    @woodworking_link.reload
    assert_equal original_title, @woodworking_link.title
  end

  test 'trainer cannot delete a link for their topic' do
    sign_in_as_trainer
    assert_no_difference 'TrainingTopicLink.count' do
      delete training_topic_link_path(@laser_topic, @laser_link)
    end
    assert_response :redirect
  end

  test 'trainer cannot delete a link for a topic they do not train' do
    sign_in_as_trainer
    assert_no_difference 'TrainingTopicLink.count' do
      delete training_topic_link_path(@woodworking_topic, @woodworking_link)
    end
    assert_response :redirect
  end

  # ─── Regular member access ────────────────────────────────────────────

  test 'regular member cannot create a link' do
    sign_in_as_regular_member
    assert_no_difference 'TrainingTopicLink.count' do
      post training_topic_links_path(@laser_topic), params: {
        training_topic_link: { title: 'Unauthorized', url: 'https://example.com/nope' }
      }
    end
    assert_response :redirect
  end

  test 'regular member cannot update a link' do
    sign_in_as_regular_member
    patch training_topic_link_path(@laser_topic, @laser_link), params: {
      training_topic_link: { title: 'Hacked' }
    }
    assert_response :redirect
  end

  test 'regular member cannot delete a link' do
    sign_in_as_regular_member
    assert_no_difference 'TrainingTopicLink.count' do
      delete training_topic_link_path(@laser_topic, @laser_link)
    end
    assert_response :redirect
  end

  # ─── Returning to the topic page ──────────────────────────────────────

  test 'link changes made from the topic page return to the topic page' do
    sign_in_as_admin

    post training_topic_links_path(@laser_topic), params: {
      return_to: 'topic_page', training_topic_link: { title: 'Manual', url: 'https://example.com/manual' }
    }
    assert_redirected_to training_catalog_topic_path(@laser_topic, anchor: 'topic-resources')

    patch training_topic_link_path(@laser_topic, @laser_link), params: {
      return_to: 'topic_page', training_topic_link: { title: 'Renamed', url: @laser_link.url }
    }
    assert_redirected_to training_catalog_topic_path(@laser_topic, anchor: 'topic-resources')
    assert_equal 'Renamed', @laser_link.reload.title

    delete training_topic_link_path(@laser_topic, @laser_link, return_to: 'topic_page')
    assert_redirected_to training_catalog_topic_path(@laser_topic, anchor: 'topic-resources')
    assert_not TrainingTopicLink.exists?(@laser_link.id)
  end
end
