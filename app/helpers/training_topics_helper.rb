module TrainingTopicsHelper
  # Data attributes that make a single-member "add training" form ask, before submitting,
  # whether an inactive trainee should be emailed about it. Active members get nothing,
  # so the form submits straight through.
  def inactive_training_notice_data(trainee)
    return {} if trainee.active?

    {
      controller: 'inactive-training-notice',
      action: 'submit->inactive-training-notice#confirm',
      inactive_training_notice_names_value: [trainee.display_name].to_json
    }
  end

  # Profile "Add training" posts one form per topic. Admins name the trainer on a shared
  # select; this stamps that choice onto the form that submits. Other callers keep the
  # inactive-member prompt and do not offer a trainer.
  def profile_add_training_form_data(trainee)
    notice = inactive_training_notice_data(trainee)
    data = { turbo: false }
    return data.merge(notice) unless current_user_admin?

    actions = ['submit->admin-add-training#stamp']
    actions << notice[:action] if notice[:action]
    data[:action] = actions.join(' ')
    data.merge(notice.except(:action))
  end
end
