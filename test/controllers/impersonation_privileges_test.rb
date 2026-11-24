require 'test_helper'

# Impersonation lets an administrator work as another member so the UI *and the logic* that
# member gets can be exercised. Authorization therefore resolves against the impersonated
# account, not the real one.
#
# That is only safe while the substitution can only ever subtract, which rests on two
# properties this file exists to pin down:
#
#   1. Impersonation is in effect only while the real account is still an administrator,
#      re-checked every request — see ApplicationController#impersonating?. An account
#      demoted mid-session stops impersonating rather than keeping the target's authority.
#   2. The way back out never depends on the impersonated member, so an administrator
#      viewing as someone with no privileges at all is never stranded.
#
# Who may act is the impersonated account; who is *recorded* as having acted is the real
# one. Both halves are asserted here.
class ImpersonationPrivilegesTest < ActionDispatch::IntegrationTest
  setup do
    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true
    @topic = training_topics(:laser_cutting)
    @trainee = users(:no_email)
    @target = users(:one)
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  # --- The session may only ever lose authority -----------------------------------------

  test 'impersonation lapses when the real account stops being an administrator' do
    TrainerCapability.create!(user: @target, training_topic: @topic)
    admin = impersonate_without_admin(@target)

    get root_path

    # The dashboard bounces a non-administrator to their own profile, and the profile it
    # picks is the demoted account's — so the session is acting as itself again rather than
    # still holding the trainer it was viewing as.
    assert_redirected_to user_path(admin)
    assert_equal admin.id, session[:user_id]
  end

  test 'a session whose real account was demoted cannot record training' do
    TrainerCapability.create!(user: @target, training_topic: @topic)
    impersonate_without_admin(@target)

    assert_no_difference 'Training.count' do
      post add_training_path(user_id: @trainee.id, topic_id: @topic.id)
    end
  end

  test 'a session whose real account was demoted cannot record training in bulk' do
    TrainerCapability.create!(user: @target, training_topic: @topic)
    impersonate_without_admin(@target)

    assert_no_difference 'Training.count' do
      post record_training_path, params: {
        training_topic_id: @topic.id,
        trained_at: Date.current.iso8601,
        trainee_ids: [@trainee.id]
      }
    end
  end

  test 'a session whose real account was demoted cannot reach the record training page' do
    TrainerCapability.create!(user: @target, training_topic: @topic)
    impersonate_without_admin(@target)

    get record_training_path

    assert_redirected_to root_path
  end

  test 'a session whose real account was demoted cannot appoint a trainer' do
    grant_privileges(@target, 'training.grant_trainer')
    impersonate_without_admin(@target)

    assert_no_difference 'TrainerCapability.count' do
      post add_trainer_capability_path(user_id: @trainee.id, topic_id: @topic.id)
    end
  end

  test 'a session whose real account was demoted cannot answer the target request queue' do
    TrainerCapability.create!(user: @target, training_topic: @topic)
    request = TrainingRequest.create!(user: @trainee, training_topic: @topic,
                                      share_contact_info: true, status: 'pending')
    impersonate_without_admin(@target)

    assert_no_difference 'Training.count' do
      post mark_trained_training_request_path(request)
    end

    assert_predicate request.reload, :pending?
  end

  test 'a session whose real account was demoted cannot upload documents' do
    TrainerCapability.create!(user: @target, training_topic: @topic)
    impersonate_without_admin(@target)

    get new_document_path

    assert_redirected_to root_path
  end

  # --- Only an administrator may start impersonating -------------------------------------

  test 'a member cannot start impersonation however many privileges they hold' do
    member = sign_in_as_plain_member
    Privilege::CATALOG.each { |entry| grant_privileges(member, entry[:key]) }

    post impersonate_user_path(@target.id)

    assert_redirected_to root_path
    assert_nil session[:impersonated_user_id]
  end

  # members.impersonate was removed from the catalog precisely so no role can hand out the
  # ability to impersonate. A non-admin who could impersonate an administrator would gain
  # authority rather than shed it, which would invert the whole model.
  test 'no privilege in the catalog confers the ability to impersonate' do
    assert_not_includes Privilege::CATALOG.pluck(:key), 'members.impersonate'
  end

  # --- The way out never depends on the impersonated member ------------------------------

  test 'an administrator impersonating a member with no privileges can still stop' do
    admin = sign_in_as_admin
    bare = User.create!(authentik_id: 'impersonation-bare', full_name: 'Bare Member')
    post impersonate_user_path(bare.id)
    assert_equal bare.id, session[:impersonated_user_id]

    delete stop_impersonation_path

    assert_nil session[:impersonated_user_id]
    assert_equal admin.id, session[:user_id]
  end

  # --- Authority follows the impersonated account ----------------------------------------

  test 'an administrator impersonating a plain member cannot record training' do
    sign_in_as_admin
    post impersonate_user_path(@target.id)

    assert_no_difference 'Training.count' do
      post add_training_path(user_id: @trainee.id, topic_id: @topic.id)
    end
  end

  test 'an administrator impersonating a plain member loses the admin navigation' do
    sign_in_as_admin
    post impersonate_user_path(@target.id)

    get users_path

    assert_response :redirect
  end

  test 'an administrator impersonating a trainer may record training for that topic' do
    TrainerCapability.create!(user: @target, training_topic: @topic)
    sign_in_as_admin
    post impersonate_user_path(@target.id)

    assert_difference 'Training.count', 1 do
      post add_training_path(user_id: @trainee.id, topic_id: @topic.id)
    end
  end

  # --- ...but the record names whoever was really at the keyboard ------------------------

  test 'training recorded while impersonating names the administrator' do
    TrainerCapability.create!(user: @target, training_topic: @topic)
    admin = sign_in_as_admin
    post impersonate_user_path(@target.id)

    post add_training_path(user_id: @trainee.id, topic_id: @topic.id)

    assert_equal admin, Training.find_by!(trainee: @trainee, training_topic: @topic).trainer
  end

  test 'a request closed while impersonating names the administrator' do
    TrainerCapability.create!(user: @target, training_topic: @topic)
    admin = sign_in_as_admin
    request = TrainingRequest.create!(user: @trainee, training_topic: @topic,
                                      share_contact_info: true, status: 'pending')
    post impersonate_user_path(@target.id)

    post mark_trained_training_request_path(request)

    assert_predicate request.reload, :responded?
    assert_equal admin, request.responded_by
  end

  test 'a reply sent while impersonating is signed by the administrator' do
    TrainerCapability.create!(user: @target, training_topic: @topic)
    admin = sign_in_as_admin
    request = TrainingRequest.create!(user: @trainee, training_topic: @topic,
                                      share_contact_info: true, status: 'pending')
    post impersonate_user_path(@target.id)

    patch training_request_path(request), params: {
      training_request: { response_body: 'Happy to help — find me on Tuesday.' }
    }

    assert_predicate request.reload, :pending?
    assert_equal admin, request.responded_by
    assert_equal admin, Message.order(:created_at).last.sender
  end

  test 'closing an already trained request while impersonating names the administrator' do
    TrainerCapability.create!(user: @target, training_topic: @topic)
    admin = sign_in_as_admin
    Training.create!(trainee: @trainee, trainer: @target, training_topic: @topic, trained_at: 1.day.ago)
    request = TrainingRequest.create!(user: @trainee, training_topic: @topic,
                                      share_contact_info: true, status: 'pending')
    post impersonate_user_path(@target.id)

    post mark_trained_training_request_path(request)

    assert_predicate request.reload, :responded?
    assert_equal admin, request.responded_by
  end

  test 'demoted admin stops impersonating and stale session does not resume on repromotion' do
    admin = sign_in_as_admin
    post impersonate_user_path(@target.id)

    get user_path(@target)
    assert_includes response.body, 'Stop Impersonating'

    admin.update!(is_admin: false)

    get user_path(@target)
    assert_not_includes response.body, 'Stop Impersonating'

    admin.update!(is_admin: true)

    get user_path(@target)
    assert_not_includes response.body, 'Stop Impersonating'
  end

  private

  # Signs in as an administrator, starts impersonating, then drops the admin flag. The
  # session is left with a plain member as its real account and a privileged member as the
  # impersonated one — the position an administrator demoted mid-session ends up in, and the
  # only way to hold an impersonation session without admin rights.
  def impersonate_without_admin(target)
    admin = sign_in_as_admin
    post impersonate_user_path(target.id)
    admin.update!(is_admin: false)
    admin
  end
end
