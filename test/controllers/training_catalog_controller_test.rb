require 'test_helper'

class TrainingCatalogControllerTest < ActionDispatch::IntegrationTest
  setup do
    @laser_topic       = training_topics(:laser_cutting)
    @woodworking_topic = training_topics(:woodworking)
    @electronics_topic = training_topics(:electronics)

    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  # Index

  test 'unauthenticated user is redirected to login' do
    get training_catalog_path
    assert_response :redirect
  end

  test 'admin sees all training topics including those not offered to members' do
    sign_in_as_admin
    get training_catalog_path

    assert_response :success
    assert_match @laser_topic.name,       response.body
    assert_match @woodworking_topic.name, response.body
    assert_match @electronics_topic.name, response.body
  end

  test 'member sees only topics offered to members' do
    sign_in_as_member
    get training_catalog_path

    assert_response :success
    assert_match @laser_topic.name,       response.body
    assert_match @woodworking_topic.name, response.body
    assert_no_match(/#{Regexp.escape(@electronics_topic.name)}/, response.body)
  end

  test 'index shows request training button when a requestable topic exists' do
    TrainerCapability.find_or_create_by!(user: users(:one), training_topic: @laser_topic)

    sign_in_as_member
    get training_catalog_path

    assert_response :success
    assert_match(/Request Training/i, response.body)
    assert_select 'a[href=?]', new_training_request_path
    assert_select 'a[href=?]', new_training_request_path(training_topic_id: @laser_topic.id)
  end

  test 'index does not show request training button when no topic has a trainer' do
    TrainerCapability.where(training_topic: [@laser_topic, @woodworking_topic]).delete_all

    sign_in_as_member
    get training_catalog_path

    assert_response :success
    assert_no_match(/Request Training/i, response.body)
  end

  test 'index does not show request training button when only trainers are inactive' do
    TrainerCapability.where(training_topic: [@laser_topic, @woodworking_topic]).delete_all
    inactive_trainer = users(:two)
    inactive_trainer.update!(membership_state: 'inactive_member')
    TrainerCapability.find_or_create_by!(user: inactive_trainer, training_topic: @laser_topic)

    sign_in_as_member
    get training_catalog_path

    assert_response :success
    assert_no_match(/Request Training/i, response.body)
  end

  test 'admin index marks whether each topic is offered to members' do
    sign_in_as_admin
    get training_catalog_path

    assert_response :success
    assert_match(/Offered/i, response.body)
  end

  test 'admin index links to record training' do
    sign_in_as_admin
    get training_catalog_path

    assert_response :success
    assert_match(/Record training/i, response.body)
    assert_match record_training_path, response.body
  end

  test 'member index does not link to record training' do
    sign_in_as_member
    get training_catalog_path

    assert_response :success
    assert_no_match record_training_path, response.body
  end

  test 'index shows a subtopic indented under its parent' do
    parent = TrainingTopic.create!(name: 'Craft Lab', offered_to_members: true)
    child = TrainingTopic.create!(
      name: 'Sewing machines', parent: parent, offered_to_members: true, description: 'Domestic machines'
    )
    TrainerCapability.create!(user: users(:one), training_topic: parent)
    TrainerCapability.create!(user: users(:one), training_topic: child)

    sign_in_as_member
    get training_catalog_path

    assert_response :success
    assert_select '.topic-nest-1', text: /Sewing machines/
    child_row = css_select("a[href='#{training_catalog_topic_path(child)}']").first.ancestors('tr').first
    assert_not_includes child_row.text, 'Craft Lab'
    assert_includes child_row.text.squish, 'Domestic machines'
    parent_row = css_select("a[href='#{training_catalog_topic_path(parent)}']").first.ancestors('tr').first
    assert_select parent_row, '.topic-nest-1', count: 0
    assert_operator response.body.index(parent.name), :<, response.body.index(child.name)
  end

  test 'index indents a grandchild under its own parent' do
    area = TrainingTopic.create!(name: 'Craft Lab', offered_to_members: true)
    child = TrainingTopic.create!(name: 'Sewing machines', parent: area, offered_to_members: true)
    grandchild = TrainingTopic.create!(name: 'Serger', parent: child, offered_to_members: true)
    TrainerCapability.create!(user: users(:one), training_topic: grandchild)

    sign_in_as_member
    get training_catalog_path

    assert_response :success
    assert_select '.topic-nest-1', text: /Sewing machines/
    assert_select '.topic-nest-2', text: /Serger/
    row = css_select("a[href='#{training_catalog_topic_path(grandchild)}']").first.ancestors('tr').first
    assert_not_includes row.text, 'Sewing machines'
    assert_select "a[href='#{training_catalog_topic_path(child)}']", count: 0
  end

  test 'index does not link a topic that cannot be requested' do
    parent = TrainingTopic.create!(name: 'Craft Lab', offered_to_members: false)
    child = TrainingTopic.create!(name: 'Sewing machines', parent: parent, offered_to_members: true)

    sign_in_as_member
    get training_catalog_path

    assert_response :success
    assert_match 'Sewing machines', response.body
    assert_match 'Craft Lab', response.body
    assert_select "a[href='#{training_catalog_topic_path(child)}']", count: 0
    assert_select "a[href='#{training_catalog_topic_path(parent)}']", count: 0
    assert_select "tr[data-href='#{training_catalog_topic_path(child)}']", count: 0
    parent_name = css_select('td strong').find { |node| node.text.strip == 'Craft Lab' }
    assert_nil parent_name.ancestors('.topic-nest-1, .topic-nest-2').first
    assert_select '.topic-nest-1', text: /Sewing machines/
  end

  test 'admin index links a topic that cannot be requested' do
    parent = TrainingTopic.create!(name: 'Craft Lab', offered_to_members: false)
    child = TrainingTopic.create!(name: 'Sewing machines', parent: parent, offered_to_members: true)

    sign_in_as_admin
    get training_catalog_path

    assert_response :success
    assert_select "a[href='#{training_catalog_topic_path(child)}']", text: 'Sewing machines'
    assert_select "a[href='#{training_catalog_topic_path(parent)}']", text: 'Craft Lab'
  end

  test 'member trained in an unoffered parent gets a link to it' do
    parent = TrainingTopic.create!(name: 'Craft Lab', offered_to_members: false)
    TrainingTopic.create!(name: 'Sewing machines', parent: parent, offered_to_members: true)
    sign_in_as_member
    Training.create!(trainee: signed_in_member, training_topic: parent, trainer: users(:one), trained_at: Time.current)

    get training_catalog_path

    assert_response :success
    assert_select "a[href='#{training_catalog_topic_path(parent)}']", text: 'Craft Lab'
  end

  test 'member trained in an unoffered topic sees it and can open it' do
    topic = TrainingTopic.create!(name: 'Internal orientation', offered_to_members: false)
    sign_in_as_member
    Training.create!(trainee: signed_in_member, training_topic: topic, trainer: users(:one), trained_at: Time.current)

    get training_catalog_path

    assert_response :success
    assert_select "a[href='#{training_catalog_topic_path(topic)}']", text: 'Internal orientation'

    get training_catalog_topic_path(topic)

    assert_response :success
    assert_match 'Internal orientation', response.body
  end

  # Show

  test 'member can view a topic that is offered to members' do
    TrainerCapability.find_or_create_by!(user: users(:one), training_topic: @laser_topic)

    sign_in_as_member
    get training_catalog_topic_path(@laser_topic)

    assert_response :success
    assert_match @laser_topic.name, response.body
    assert_match(/Trainers/i, response.body)
    assert_match(/Trained Members/i, response.body)
    assert_select '#topic-resources h2', text: /Resources/
  end

  test 'member cannot view a topic that is not offered to members' do
    sign_in_as_member
    get training_catalog_topic_path(@electronics_topic)

    assert_redirected_to training_catalog_path
    assert_equal 'That training topic is not available.', flash[:alert]
  end

  test 'admin can view a topic that is not offered to members' do
    sign_in_as_admin
    get training_catalog_topic_path(@electronics_topic)

    assert_response :success
    assert_match @electronics_topic.name, response.body
  end

  test 'show lists trainers and trainees for the topic' do
    trainer = users(:one)
    trainee = users(:two)
    TrainerCapability.find_or_create_by!(user: trainer, training_topic: @laser_topic)
    Training.find_or_create_by!(trainee: trainee, training_topic: @laser_topic) do |t|
      t.trainer    = trainer
      t.trained_at = Time.current
    end

    sign_in_as_admin
    get training_catalog_topic_path(@laser_topic)

    assert_response :success
    assert_match trainer.display_name, response.body
    assert_match trainee.display_name, response.body
  end

  test 'show lists training topic links' do
    link = training_topic_links(:laser_safety_guide)

    sign_in_as_admin
    get training_catalog_topic_path(@laser_topic)

    assert_response :success
    assert_match link.title, response.body
    assert_match link.url, response.body
  end

  test 'show displays request training button for a trainable topic' do
    TrainerCapability.find_or_create_by!(user: users(:one), training_topic: @laser_topic)

    sign_in_as_member
    get training_catalog_topic_path(@laser_topic)

    assert_response :success
    assert_match(/Request Training/i, response.body)
    assert_select 'a[href=?]', new_training_request_path(training_topic_id: @laser_topic.id)
  end

  test 'show does not display request training button when topic has no trainer' do
    TrainerCapability.where(training_topic: @laser_topic).delete_all

    sign_in_as_member
    get training_catalog_topic_path(@laser_topic)

    assert_response :success
    assert_no_match(/Request Training/i, response.body)
  end

  test 'show lists inactive trainers for admins but not for members' do
    active_trainer   = users(:one)
    inactive_trainer = users(:two)
    inactive_trainer.update!(membership_state: 'inactive_member')
    TrainerCapability.find_or_create_by!(user: active_trainer,   training_topic: @laser_topic)
    TrainerCapability.find_or_create_by!(user: inactive_trainer, training_topic: @laser_topic)

    sign_in_as_admin
    get training_catalog_topic_path(@laser_topic)

    assert_response :success
    assert_match active_trainer.display_name, response.body
    assert_match inactive_trainer.display_name, response.body
    assert_match 'Inactive', response.body

    sign_in_as_member
    get training_catalog_topic_path(@laser_topic)

    assert_response :success
    assert_match active_trainer.display_name, response.body
    assert_no_match(/#{Regexp.escape(inactive_trainer.display_name)}/, response.body)
  end

  test 'show marks inactive trained members for admins' do
    trainer = users(:one)
    inactive_trainee = users(:two)
    inactive_trainee.update!(membership_state: 'inactive_member')
    TrainerCapability.find_or_create_by!(user: trainer, training_topic: @laser_topic)
    Training.find_or_create_by!(trainee: inactive_trainee, training_topic: @laser_topic) do |t|
      t.trainer = trainer
      t.trained_at = Time.current
    end

    sign_in_as_admin
    get training_catalog_topic_path(@laser_topic)

    assert_response :success
    assert_match inactive_trainee.display_name, response.body
    assert_match 'Inactive', response.body
  end

  test 'admin index shows trainer and trained counts split by active status' do
    active_trainer = users(:one)
    inactive_trainer = users(:two)
    inactive_trainer.update!(membership_state: 'inactive_member')
    inactive_trainee = users(:no_email)
    inactive_trainee.update!(membership_state: 'inactive_member')

    TrainerCapability.find_or_create_by!(user: active_trainer, training_topic: @laser_topic)
    TrainerCapability.find_or_create_by!(user: inactive_trainer, training_topic: @laser_topic)
    Training.find_or_create_by!(trainee: inactive_trainee, training_topic: @laser_topic) do |t|
      t.trainer = active_trainer
      t.trained_at = Time.current
    end

    sign_in_as_admin
    get training_catalog_path

    assert_response :success
    laser_link = css_select("a[href='#{training_catalog_topic_path(@laser_topic)}']").first
    row_text = laser_link.ancestors('tr').first.text.squish
    assert_includes row_text, '2'
    assert_includes row_text, '1 active'
    assert_includes row_text, '1 inactive'
  end

  test 'needs trainers filter ignores topics with only inactive trainers' do
    inactive_trainer = users(:two)
    inactive_trainer.update!(membership_state: 'inactive_member')
    TrainerCapability.where(training_topic: @laser_topic).delete_all
    TrainerCapability.find_or_create_by!(user: inactive_trainer, training_topic: @laser_topic)

    sign_in_as_admin
    get training_catalog_path(training_filter: 'needs_trainers')

    assert_response :success
    assert_match @laser_topic.name, response.body
  end

  test 'show does not display request training button when only trainers are inactive' do
    inactive_trainer = users(:two)
    inactive_trainer.update!(membership_state: 'inactive_member')
    TrainerCapability.where(training_topic: @laser_topic).delete_all
    TrainerCapability.find_or_create_by!(user: inactive_trainer, training_topic: @laser_topic)

    sign_in_as_member
    get training_catalog_topic_path(@laser_topic)

    assert_response :success
    assert_no_match(/Request Training/i, response.body)
  end

  test 'show renders resources after trainers and trained members' do
    TrainerCapability.find_or_create_by!(user: users(:one), training_topic: @laser_topic)

    sign_in_as_admin
    get training_catalog_topic_path(@laser_topic)

    assert_response :success
    resources_index = response.body.index('id="topic-resources"')
    trainers_index  = response.body.index('Trainers</h2>')
    trained_index   = response.body.index('Trained Members')

    assert resources_index, 'expected Resources section'
    assert trainers_index < resources_index, 'expected Resources to appear after Trainers'
    assert trained_index < resources_index, 'expected Resources to appear after Trained Members'
  end

  test 'member without the links privilege sees resources but cannot edit them' do
    sign_in_as_member
    get training_catalog_topic_path(@laser_topic)

    assert_response :success
    assert_select '#topic-resources'
    assert_select "#topic-resources form[action='#{training_topic_links_path(@laser_topic)}']", count: 0
    assert_select '#topic-resources details', count: 0
    assert_no_match 'Add document', response.body
  end

  test 'curator with the links privilege for the topic can add, edit, and remove links on the topic page' do
    sign_in_as_member
    grant_privileges(signed_in_member, 'training.topics.manage_links', topic: @laser_topic)

    get training_catalog_topic_path(@laser_topic)
    assert_select "#topic-resources form[action='#{training_topic_links_path(@laser_topic)}']"
    link = @laser_topic.links.first
    assert_select "#topic-link-#{link.id} form[action='#{training_topic_link_path(@laser_topic, link)}']"

    get training_catalog_topic_path(@woodworking_topic)
    assert_select "#topic-resources form[action='#{training_topic_links_path(@woodworking_topic)}']", count: 0
  end

  test 'member who can manage topic documents is offered add and edit document links' do
    sign_in_as_member
    grant_privileges(signed_in_member, 'training.documents.manage', topic: @laser_topic)

    get training_catalog_topic_path(@laser_topic)

    assert_select "#topic-resources a[href^='#{new_document_path}']", text: 'Add document'
  end

  test 'curator who manages a parent topic sees a subtopic document on the topic page' do
    sign_in_as_member
    parent = TrainingTopic.create!(name: 'Curated area', offered_to_members: true)
    grant_privileges(signed_in_member, 'training.documents.manage', topic: parent)
    subtopic = TrainingTopic.create!(name: 'Curated subtopic', parent: parent, offered_to_members: true)
    doc = Document.new(title: 'Subtopic handbook', training_topics: [subtopic])
    doc.file.attach(io: StringIO.new('handbook'), filename: 'handbook.txt', content_type: 'text/plain')
    doc.save!

    get training_catalog_topic_path(subtopic)

    assert_select '#topic-resources', text: /Subtopic handbook/
  end

  test 'show displays edit button for admin' do
    sign_in_as_admin
    get training_catalog_topic_path(@laser_topic)

    assert_response :success
    assert_match edit_training_topic_path(@laser_topic), response.body
    assert_match(/>\s*Edit\s*</, response.body)
  end

  test 'show does not display edit button for a member without topic privileges' do
    sign_in_as_member
    get training_catalog_topic_path(@laser_topic)

    assert_response :success
    assert_no_match(/#{Regexp.escape(edit_training_topic_path(@laser_topic))}/, response.body)
  end

  # Stewards and curators

  test 'curator can open an unoffered topic they curate and see its edit button' do
    sign_in_as_member
    area = TrainingTopic.create!(name: 'Craft Lab', offered_to_members: false)
    grant_privileges(signed_in_member, 'training.topics.manage_links', topic: area)

    get training_catalog_topic_path(area)

    assert_response :success
    assert_select "a[href='#{edit_training_topic_path(area)}']", text: /Edit/
  end

  test 'curator can open an unoffered direct subtopic of a topic they curate' do
    sign_in_as_member
    area = TrainingTopic.create!(name: 'Craft Lab', offered_to_members: false)
    subtopic = TrainingTopic.create!(name: 'Sewing machines', parent: area, offered_to_members: false)
    grant_privileges(signed_in_member, 'training.topics.edit_details', topic: area)

    get training_catalog_topic_path(subtopic)

    assert_response :success
    assert_select "a[href='#{edit_training_topic_path(subtopic)}']", text: /Edit/
  end

  test 'curator cannot open an unrelated unoffered topic' do
    sign_in_as_member
    area = TrainingTopic.create!(name: 'Craft Lab', offered_to_members: false)
    grant_privileges(signed_in_member, 'training.topics.manage_links', topic: area)
    unrelated = TrainingTopic.create!(name: 'Metal shop', offered_to_members: false)

    get training_catalog_topic_path(unrelated)

    assert_redirected_to training_catalog_path
  end

  test 'curator sees no edit button on an offered topic they do not curate' do
    sign_in_as_member
    area = TrainingTopic.create!(name: 'Craft Lab', offered_to_members: false)
    grant_privileges(signed_in_member, 'training.topics.manage_links', topic: area)

    get training_catalog_topic_path(@laser_topic)

    assert_response :success
    assert_select "a[href='#{edit_training_topic_path(@laser_topic)}']", count: 0
  end

  test 'catalog view_all links an unoffered topic the member is not trained in' do
    hidden = TrainingTopic.create!(name: 'Closed shop tour', offered_to_members: false)
    sign_in_as_member
    grant_privileges(signed_in_member, 'training.catalog.view_all')

    get training_catalog_path

    assert_response :success
    assert_select "a[href='#{training_catalog_topic_path(hidden)}']", text: 'Closed shop tour'
  end

  test 'catalog index lists unoffered topics the curator may edit and no others' do
    sign_in_as_member
    area = TrainingTopic.create!(name: 'Craft Lab', offered_to_members: false)
    subtopic = TrainingTopic.create!(name: 'Sewing machines', parent: area, offered_to_members: false)
    grant_privileges(signed_in_member, 'training.documents.manage', topic: area)
    TrainingTopic.create!(name: 'Metal shop', offered_to_members: false)

    get training_catalog_path

    assert_response :success
    assert_match area.name, response.body
    assert_match subtopic.name, response.body
    assert_no_match 'Metal shop', response.body
    assert_match @laser_topic.name, response.body
    assert_select "a[href='#{training_catalog_topic_path(area)}']", text: area.name
    assert_select "a[href='#{training_catalog_topic_path(subtopic)}']", text: subtopic.name
  end

  test 'member can open an unoffered topic that shares its roster and contact it from the list' do
    parent = TrainingTopic.create!(
      name: 'Steward Woodshop', offered_to_members: false,
      trained_members_visible: true, trained_members_contactable: true
    )
    TrainingTopic.create!(name: 'Table saw', parent: parent, offered_to_members: true)
    steward = users(:two)
    private_user = users(:private_profile_user)
    Training.create!(trainee: steward, training_topic: parent, trainer: users(:one), trained_at: Time.current)
    Training.create!(trainee: private_user, training_topic: parent, trainer: users(:one), trained_at: Time.current)

    sign_in_as_member
    get training_catalog_path

    assert_response :success
    assert_select "a[href='#{training_catalog_topic_path(parent)}']", text: 'Steward Woodshop'
    assert_select "a[href='#{user_path(steward)}']", text: steward.display_name
    assert_select "a[href='#{user_path(private_user)}']", count: 0
    assert_match private_user.display_name, response.body
    contact = "button[data-contact-url='#{training_catalog_topic_contact_path(parent)}']"
    assert_select contact, text: /Contact/
    detail = css_select(contact).first['data-contact-detail']
    assert_includes detail, steward.display_name
    assert_includes detail, private_user.display_name

    assert_difference 'Message.count', 2 do
      post training_catalog_topic_contact_path(parent),
           params: { subject: 'Shop', body: 'Who is in today?', return_to: 'catalog' }
    end
    assert_redirected_to training_catalog_path

    get training_catalog_topic_path(parent)

    assert_response :success
    assert_select '#trained-members a[href=?]', user_path(steward), text: steward.display_name
    assert_select '#contact-trained-members'
  end

  test 'member does not see who is trained until the topic allows it' do
    trainee = users(:two)
    Training.create!(trainee: trainee, training_topic: @laser_topic, trainer: users(:one), trained_at: Time.current)

    sign_in_as_member
    get training_catalog_topic_path(@laser_topic)

    assert_response :success
    assert_select '#trained-members', text: /1 member trained/
    assert_no_match(/#{Regexp.escape(trainee.display_name)}/, response.body)
    assert_select '#contact-trained-members', count: 0
  end

  test 'member sees trained names and links shared profiles when the topic allows it' do
    shared = users(:two)
    private_user = users(:private_profile_user)
    @laser_topic.update!(trained_members_visible: true, trained_members_contactable: true)
    Training.create!(trainee: shared, training_topic: @laser_topic, trainer: users(:one), trained_at: Time.current)
    Training.create!(trainee: private_user, training_topic: @laser_topic, trainer: users(:one),
                     trained_at: Time.current)

    sign_in_as_member
    get training_catalog_topic_path(@laser_topic)

    assert_response :success
    assert_select '#trained-members a[href=?]', user_path(shared), text: shared.display_name
    assert_select '#trained-members a[href=?]', user_path(private_user), count: 0
    assert_select '#trained-members', text: /#{Regexp.escape(private_user.display_name)}/
    assert_select "form[action='#{training_catalog_topic_contact_path(@laser_topic)}']"
  end

  test 'admin gets a profile link even when the profile is private and the topic has not opted in' do
    private_user = users(:private_profile_user)
    Training.create!(trainee: private_user, training_topic: @laser_topic, trainer: users(:one),
                     trained_at: Time.current)

    sign_in_as_admin
    get training_catalog_topic_path(@laser_topic)

    assert_response :success
    assert_select '#trained-members a[href=?]', user_path(private_user), text: private_user.display_name
  end

  test 'a trainer with a private profile is not a link for a member' do
    trainer = users(:private_profile_user)
    TrainerCapability.create!(user: trainer, training_topic: @laser_topic)

    sign_in_as_member
    get training_catalog_topic_path(@laser_topic)

    assert_response :success
    assert_match trainer.display_name, response.body
    assert_select "a[href='#{user_path(trainer)}']", count: 0

    sign_in_as_admin
    get training_catalog_topic_path(@laser_topic)

    assert_select "a[href='#{user_path(trainer)}']", text: trainer.display_name
  end

  test 'member cannot message trained members until the topic allows it' do
    Training.create!(trainee: users(:two), training_topic: @laser_topic, trainer: users(:one),
                     trained_at: Time.current)

    sign_in_as_member

    assert_no_difference 'Message.count' do
      post training_catalog_topic_contact_path(@laser_topic), params: { subject: 'Hi', body: 'Question' }
    end

    assert_redirected_to training_catalog_topic_path(@laser_topic)
    assert_match(/cannot contact/, flash[:alert])
  end

  test 'catalog contact hides names when the topic allows messages but not the list' do
    topic = TrainingTopic.create!(
      name: 'Steward Shop', offered_to_members: false, trained_members_contactable: true
    )
    trainee = users(:two)
    Training.create!(trainee: trainee, training_topic: topic, trainer: users(:one), trained_at: Time.current)

    sign_in_as_member
    get training_catalog_path

    assert_response :success
    contact = "button[data-contact-url='#{training_catalog_topic_contact_path(topic)}']"
    assert_select contact, text: /Contact/
    assert_equal 'This goes to the members trained in this topic. They can reply to you.',
                 css_select(contact).first['data-contact-detail']
    assert_no_match(/#{Regexp.escape(trainee.display_name)}/, response.body)
  end

  test 'member messages everyone trained when the topic allows it and is left out of their own copy' do
    @laser_topic.update!(trained_members_contactable: true)
    sign_in_as_member
    Training.create!(trainee: users(:two), training_topic: @laser_topic, trainer: users(:one),
                     trained_at: Time.current)
    Training.create!(trainee: signed_in_member, training_topic: @laser_topic, trainer: users(:one),
                     trained_at: Time.current)

    assert_difference 'Message.count', 1 do
      post training_catalog_topic_contact_path(@laser_topic),
           params: { subject: 'Shop hours', body: 'When are you in?' }
    end

    assert_redirected_to training_catalog_topic_path(@laser_topic)
    assert_equal 'Message sent to 1 member.', flash[:notice]
    message = Message.order(:id).last
    assert_equal users(:two).id, message.recipient_id
    assert_equal signed_in_member.id, message.sender_id
  end

  test 'a member trained in the parent sees and can message an unoffered subtopic' do
    parent = TrainingTopic.create!(name: 'Steward Woodshop', offered_to_members: true)
    child = TrainingTopic.create!(name: 'Table saw', parent: parent, offered_to_members: false)
    trainee = users(:private_profile_user)
    Training.create!(trainee: trainee, training_topic: child, trainer: users(:one), trained_at: Time.current)

    sign_in_as_member
    get training_catalog_topic_path(child)
    assert_redirected_to training_catalog_path

    Training.create!(trainee: signed_in_member, training_topic: parent, trainer: users(:one), trained_at: Time.current)

    get training_catalog_path
    assert_response :success
    assert_select "a[href='#{training_catalog_topic_path(child)}']", text: 'Table saw'
    contact = "button[data-contact-url='#{training_catalog_topic_contact_path(child)}']"
    assert_select contact, text: /Contact/
    assert_equal 'This goes to the members trained in this topic. They can reply to you.',
                 css_select(contact).first['data-contact-detail']
    assert_no_match(/#{Regexp.escape(trainee.display_name)}/, response.body)

    get training_catalog_topic_path(child)
    assert_response :success
    assert_select '#trained-members', text: /#{Regexp.escape(trainee.display_name)}/
    assert_select "#trained-members a[href='#{user_path(trainee)}']", count: 0

    assert_difference 'Message.count', 1 do
      post training_catalog_topic_contact_path(child), params: { subject: 'Saw', body: 'Who is next?' }
    end

    assert_equal trainee.id, Message.order(:id).last.recipient_id
  end

  test 'show returns friendly error for unknown topic' do
    sign_in_as_admin
    get training_catalog_topic_path(id: 999_999_999)

    assert_redirected_to training_catalog_path
    assert_equal 'Training topic not found.', flash[:alert]
  end

  # Navbar

  test 'navbar includes training link for admin' do
    sign_in_as_admin
    get root_path

    assert_response :success
    assert_match(%r{>Training</a>}, response.body)
    assert_match training_catalog_path, response.body
  end

  test 'navbar includes training link for member' do
    sign_in_as_member
    get training_catalog_path

    assert_response :success
    assert_match(%r{>Training</a>}, response.body)
    assert_match training_catalog_path, response.body
  end

  test 'navbar shows dashboard shortcut icon for non-admin member' do
    sign_in_as_member
    member = User.find_by(authentik_id: "local:#{local_accounts(:regular_member).id}")

    get training_catalog_path

    assert_response :success
    assert_match(/aria-label="Dashboard"/, response.body)
    assert_match(/bi bi-speedometer2/, response.body)
    assert_match user_path(member, tab: :dashboard), response.body
  end

  test 'navbar shows home icon for admin rather than dashboard shortcut' do
    sign_in_as_admin
    get root_path

    assert_response :success
    assert_match(/aria-label="Home"/, response.body)
    assert_no_match(/aria-label="Dashboard"/, response.body)
  end

  private

  def sign_in_as_admin
    post local_login_path, params: {
      session: { email: local_accounts(:active_admin).email, password: 'localpassword123' }
    }
  end

  def sign_in_as_member
    post local_login_path, params: {
      session: { email: local_accounts(:regular_member).email, password: 'memberpassword123' }
    }
  end

  def signed_in_member
    User.find_by!('authentik_id LIKE ?', "local:#{local_accounts(:regular_member).id}")
  end
end
