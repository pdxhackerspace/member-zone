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
end
