require 'test_helper'

class DocumentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @laser_topic = training_topics(:laser_cutting)
    @woodworking_topic = training_topics(:woodworking)
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

  def create_document_for_topic(topic, title: 'Test Doc')
    doc = Document.new(title: title)
    doc.file.attach(
      io: StringIO.new('test file content'),
      filename: 'test.txt',
      content_type: 'text/plain'
    )
    doc.save!
    doc.training_topics << topic
    doc
  end

  # ─── Documents index (admin only) ─────────────────────────────────────

  test 'admin can access documents index' do
    sign_in_as_admin
    get documents_path
    assert_response :success
  end

  test 'trainer cannot access documents index' do
    sign_in_as_trainer
    get documents_path
    assert_response :redirect
  end

  test 'regular member cannot access documents index' do
    sign_in_as_regular_member
    get documents_path
    assert_response :redirect
  end

  test 'unauthenticated user cannot access documents index' do
    get documents_path
    assert_redirected_to login_path
  end

  # ─── New document ──────────────────────────────────────────────────────

  test 'admin can access new document page' do
    sign_in_as_admin
    get new_document_path
    assert_response :success
  end

  test 'trainer can access new document page' do
    sign_in_as_trainer
    get new_document_path
    assert_response :success
  end

  test 'trainer new document page only shows their trainable topics' do
    sign_in_as_trainer
    get new_document_path
    assert_response :success
    assert_match @laser_topic.name, response.body
    assert_no_match @woodworking_topic.name, response.body
  end

  test 'admin new document page shows all topics' do
    sign_in_as_admin
    get new_document_path
    assert_response :success
    assert_match @laser_topic.name, response.body
    assert_match @woodworking_topic.name, response.body
  end

  test 'trainer new document page does not show show_on_all_profiles' do
    sign_in_as_trainer
    get new_document_path
    assert_response :success
    assert_no_match 'Show on all member profiles', response.body
  end

  test 'admin new document page shows show_on_all_profiles' do
    sign_in_as_admin
    get new_document_path
    assert_response :success
    assert_match 'Show on all member profiles', response.body
  end

  test 'regular member cannot access new document page' do
    sign_in_as_regular_member
    get new_document_path
    assert_response :redirect
  end

  # ─── Create document ───────────────────────────────────────────────────

  test 'admin can create a document' do
    sign_in_as_admin
    assert_difference 'Document.count', 1 do
      post documents_path, params: {
        document: {
          title: 'Admin Doc',
          file: fixture_file_upload('test/fixtures/files/test_document.txt', 'text/plain'),
          show_on_all_profiles: true,
          training_topic_ids: [@laser_topic.id]
        }
      }
    end
    doc = Document.last
    assert doc.show_on_all_profiles?
    assert_includes doc.training_topic_ids, @laser_topic.id
  end

  test 'trainer can create a document for their topic' do
    sign_in_as_trainer
    assert_difference 'Document.count', 1 do
      post documents_path, params: {
        document: {
          title: 'Trainer Doc',
          file: fixture_file_upload('test/fixtures/files/test_document.txt', 'text/plain'),
          training_topic_ids: [@laser_topic.id]
        }
      }
    end
    doc = Document.last
    assert_includes doc.training_topic_ids, @laser_topic.id
  end

  test 'trainer cannot set show_on_all_profiles' do
    sign_in_as_trainer
    post documents_path, params: {
      document: {
        title: 'Trainer Doc',
        file: fixture_file_upload('test/fixtures/files/test_document.txt', 'text/plain'),
        show_on_all_profiles: true,
        training_topic_ids: [@laser_topic.id]
      }
    }
    doc = Document.last
    assert_not doc.show_on_all_profiles?
  end

  test 'trainer cannot associate document with topics they do not train' do
    sign_in_as_trainer
    post documents_path, params: {
      document: {
        title: 'Sneaky Doc',
        file: fixture_file_upload('test/fixtures/files/test_document.txt', 'text/plain'),
        training_topic_ids: [@woodworking_topic.id]
      }
    }
    doc = Document.last
    assert_not_includes doc.training_topic_ids, @woodworking_topic.id
  end

  test 'regular member cannot create a document' do
    sign_in_as_regular_member
    assert_no_difference 'Document.count' do
      post documents_path, params: {
        document: {
          title: 'Unauthorized',
          file: fixture_file_upload('test/fixtures/files/test_document.txt', 'text/plain'),
          training_topic_ids: [@laser_topic.id]
        }
      }
    end
    assert_response :redirect
  end

  # ─── Edit document ─────────────────────────────────────────────────────

  test 'admin can edit any document' do
    sign_in_as_admin
    doc = create_document_for_topic(@laser_topic)
    get edit_document_path(doc)
    assert_response :success
  end

  test 'trainer can edit a document associated with their topic' do
    sign_in_as_trainer
    doc = create_document_for_topic(@laser_topic, title: 'Trainer Editable Doc')
    get edit_document_path(doc)
    assert_response :success
  end

  test 'trainer cannot edit a document not associated with their topic' do
    sign_in_as_trainer
    doc = create_document_for_topic(@woodworking_topic, title: 'Not My Doc')
    get edit_document_path(doc)
    assert_redirected_to root_path
  end

  test 'trainer edit page only shows their trainable topics' do
    sign_in_as_trainer
    doc = create_document_for_topic(@laser_topic)
    get edit_document_path(doc)
    assert_response :success
    assert_match @laser_topic.name, response.body
    assert_no_match @woodworking_topic.name, response.body
  end

  test 'trainer edit page does not show show_on_all_profiles' do
    sign_in_as_trainer
    doc = create_document_for_topic(@laser_topic)
    get edit_document_path(doc)
    assert_response :success
    assert_no_match 'Show on all member profiles', response.body
  end

  # ─── Update document ───────────────────────────────────────────────────

  test 'trainer can update a document associated with their topic' do
    sign_in_as_trainer
    doc = create_document_for_topic(@laser_topic, title: 'Old Title')
    patch document_path(doc), params: {
      document: { title: 'New Title' }
    }
    doc.reload
    assert_equal 'New Title', doc.title
  end

  test 'trainer cannot update a document not associated with their topic' do
    sign_in_as_trainer
    doc = create_document_for_topic(@woodworking_topic, title: 'Woodworking Doc')
    patch document_path(doc), params: {
      document: { title: 'Hacked Title' }
    }
    assert_redirected_to root_path
    doc.reload
    assert_equal 'Woodworking Doc', doc.title
  end

  test 'trainer cannot change show_on_all_profiles via update' do
    sign_in_as_trainer
    doc = create_document_for_topic(@laser_topic)
    patch document_path(doc), params: {
      document: { show_on_all_profiles: true }
    }
    doc.reload
    assert_not doc.show_on_all_profiles?
  end

  # ─── Destroy document ──────────────────────────────────────────────────

  test 'admin can destroy any document' do
    sign_in_as_admin
    doc = create_document_for_topic(@laser_topic)
    assert_difference 'Document.count', -1 do
      delete document_path(doc)
    end
  end

  test 'trainer can destroy a document associated with their topic' do
    sign_in_as_trainer
    doc = create_document_for_topic(@laser_topic, title: 'Delete Me')
    assert_difference 'Document.count', -1 do
      delete document_path(doc)
    end
  end

  test 'trainer cannot destroy a document not associated with their topic' do
    sign_in_as_trainer
    doc = create_document_for_topic(@woodworking_topic, title: 'Not Mine')
    assert_no_difference 'Document.count' do
      delete document_path(doc)
    end
    assert_redirected_to root_path
  end

  test 'regular member cannot destroy a document' do
    sign_in_as_regular_member
    doc = create_document_for_topic(@laser_topic)
    assert_no_difference 'Document.count' do
      delete document_path(doc)
    end
    assert_response :redirect
  end

  # ─── Download document ─────────────────────────────────────────────────

  test 'trainer can download a document from their topic' do
    sign_in_as_trainer
    doc = create_document_for_topic(@laser_topic)
    get download_document_path(doc)
    assert_response :success
  end

  test 'curator who manages a parent topic can download a subtopic document without being trained in it' do
    sign_in_as_regular_member
    member = User.find_by!('authentik_id LIKE ?', "local:#{local_accounts(:regular_member).id}")
    parent = TrainingTopic.create!(name: 'Curated area', offered_to_members: true)
    grant_privileges(member, 'training.documents.manage', topic: parent)
    subtopic = TrainingTopic.create!(name: 'Curated subtopic', parent: parent, offered_to_members: true)
    doc = create_document_for_topic(subtopic)

    get download_document_path(doc)

    assert_response :success
  end

  test 'return_to_topic redirects back to topic page after create' do
    sign_in_as_trainer
    post documents_path, params: {
      document: {
        title: 'Topic Doc',
        file: fixture_file_upload('test/fixtures/files/test_document.txt', 'text/plain'),
        training_topic_ids: [@laser_topic.id]
      },
      return_to_topic: @laser_topic.id
    }
    assert_redirected_to edit_training_topic_path(@laser_topic)
  end

  test 'return_to_topic redirects back to topic page after destroy' do
    sign_in_as_trainer
    doc = create_document_for_topic(@laser_topic)
    delete document_path(doc, return_to_topic: @laser_topic.id)
    assert_redirected_to edit_training_topic_path(@laser_topic)
  end
end
