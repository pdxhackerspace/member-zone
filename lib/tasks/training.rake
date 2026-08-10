namespace :training do
  desc 'Mark all users with RFID keys as trained on Building Access'
  task rfid_building_access: :environment do
    puts 'Building Access Training for RFID Key Holders'
    puts '=' * 50
    puts ''

    topic = TrainingTopic.building_access
    unless topic
      puts 'ERROR: Building Access training topic not found.'
      puts 'Set it under Settings > Membership, or create a topic named "Building Access".'
      exit 1
    end

    puts "Training topic: #{topic.name} (ID: #{topic.id})"
    puts ''

    # Find all users who have at least one RFID key
    users_with_rfids = User.joins(:rfids).distinct

    puts "Found #{users_with_rfids.count} users with RFID keys"
    puts ''

    added_count = 0
    skipped_count = 0

    users_with_rfids.find_each do |user|
      # Check if already trained
      if Training.exists?(trainee: user, training_topic: topic)
        skipped_count += 1
        next
      end

      # Add training
      Training.create!(
        trainee: user,
        trainer: nil, # No specific trainer for bulk assignment
        training_topic: topic,
        trained_at: Time.current
      )

      added_count += 1
      puts "  Trained: #{user.display_name}"
    end

    puts ''
    puts '=' * 50
    puts 'Summary:'
    puts "  Added training: #{added_count} users"
    puts "  Already trained: #{skipped_count} users"
    puts ''
    puts 'Done!'
  end

  desc 'Preview Building Access training assignment (dry run)'
  task preview_rfid_building_access: :environment do
    puts 'DRY RUN - No changes will be made'
    puts '=' * 50
    puts ''

    topic = TrainingTopic.building_access
    unless topic
      puts 'ERROR: Building Access training topic not found.'
      puts 'Set it under Settings > Membership, or create a topic named "Building Access".'
      exit 1
    end

    puts "Training topic: #{topic.name} (ID: #{topic.id})"
    puts ''

    # Find all users who have at least one RFID key
    users_with_rfids = User.joins(:rfids).distinct

    puts "Found #{users_with_rfids.count} users with RFID keys"
    puts ''

    would_add = []
    would_skip = []

    users_with_rfids.find_each do |user|
      if Training.exists?(trainee: user, training_topic: topic)
        would_skip << user
      else
        would_add << user
      end
    end

    if would_add.any?
      puts "Would add training for #{would_add.count} users:"
      would_add.each { |u| puts "  - #{u.display_name}" }
      puts ''
    end

    puts "Already trained: #{would_skip.count} users"
    puts ''

    puts "Run 'rake training:rfid_building_access' to apply changes."
  end
end
