module BulkTrainingRecording
  extend ActiveSupport::Concern

  # One submission covers every selected member in every selected topic. "Trained" records a
  # training in each; "Trainer" appoints each of them a trainer, recording the training first
  # where it is missing. Nothing is written unless the actor may do it in every topic.
  def create_bulk
    topics = bulk_training_topics
    return redirect_to(record_training_path, alert: 'Pick at least one topic.') if topics.empty?

    refused = topics.reject { |topic| bulk_topic_permitted?(topic) }
    return redirect_to(record_training_path, alert: bulk_refusal_message(refused)) if refused.any?

    trainee_ids = Array(params[:trainee_ids]).compact_blank.map(&:to_s).uniq
    if trainee_ids.empty?
      return redirect_to(record_training_path, alert: 'Add at least one member before recording training.')
    end

    totals = topics.map { |topic| bulk_record_topic(topic, trainee_ids) }
    finish_bulk(topics, totals, trainee_ids)
  end

  private

  def recording_trainers?
    params[:record_as] == 'trainer'
  end

  # The form posts training_topic_ids[]; a single training_topic_id still works for links
  # and scripts written against the one-topic form.
  def bulk_training_topics
    ids = Array(params[:training_topic_ids]).compact_blank
    ids = Array(params[:training_topic_id]).compact_blank if ids.empty?
    TrainingTopic.where(id: ids.uniq).order(:name).to_a
  end

  def bulk_topic_permitted?(topic)
    recording_trainers? ? can_manage_trainer_capability?(topic) : can_train_topic?(topic)
  end

  def bulk_refusal_message(topics)
    action = recording_trainers? ? 'appoint trainers for' : 'train'
    "You don't have permission to #{action} #{topics.map(&:name).to_sentence}."
  end

  def bulk_record_topic(topic, trainee_ids)
    options = { current_user: true_user, training_topic: topic, trainee_ids: trainee_ids,
                trainer: selected_trainer_for_recording, trained_at: parsed_trained_at,
                notify_inactive: notify_inactive? }
    if recording_trainers?
      result = TrainerAppointer.new(**options).call
      { done: result.appointed_count, trained: result.trained_count, skipped: result.skipped_count,
        inactive: result.inactive_count }
    else
      result = TrainingRecorder.new(**options).call
      { done: result.recorded_count, trained: 0, skipped: result.skipped_count, inactive: result.inactive_count }
    end
  end

  def finish_bulk(topics, totals, trainee_ids)
    sum = ->(key) { totals.sum { |total| total[key] } }
    if sum.call(:done).zero?
      return redirect_to(record_training_path, alert: 'Nothing was recorded. Everyone selected was already ' \
                                                      "#{recording_trainers? ? 'a trainer' : 'trained'} " \
                                                      'or could not be.')
    end

    redirect_to training_catalog_path, notice: bulk_notice(topics, sum, trainee_ids)
  end

  def bulk_notice(topics, sum, trainee_ids)
    done = sum.call(:done)
    headline = if recording_trainers?
                 "Made #{done} #{'trainer'.pluralize(done)} in #{topics.map(&:name).to_sentence}."
               else
                 "Recorded #{done} #{'training'.pluralize(done)} in #{topics.map(&:name).to_sentence}."
               end
    trained = sum.call(:trained)
    headline += " Also recorded #{trained} #{'training'.pluralize(trained)}." if trained.positive?
    headline += " #{sum.call(:skipped)} skipped." if sum.call(:skipped).positive?
    headline + bulk_inactive_note(sum.call(:inactive).positive? ? inactive_member_count(trainee_ids) : 0)
  end

  # The services count events, so a member in three topics would count three times; the
  # note is about people.
  def inactive_member_count(trainee_ids)
    User.where(id: trainee_ids).count { |user| !user.active? && !user.banned? }
  end

  def bulk_inactive_note(count)
    return '' unless count.positive?

    label = 'inactive member'.pluralize(count)
    verb = recording_trainers? ? 'appointed' : 'trained'
    " #{count} #{label} #{verb} and #{notify_inactive? ? 'notified' : 'not notified'}."
  end
end
