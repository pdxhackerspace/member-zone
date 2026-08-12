if LocalAuthConfig.enabled? && LocalAuthConfig.settings.default_email.present?
  email = LocalAuthConfig.settings.default_email
  password = LocalAuthConfig.settings.default_password || SecureRandom.base58(24)
  existed = LocalAccount.by_email(email).exists?

  LocalAccount.provision!(
    email: email,
    password: password,
    full_name: LocalAuthConfig.settings.default_full_name
  )

  Rails.logger.debug { existed ? "Local admin updated: #{email}" : "Local admin created: #{email} / #{password}" }

  LocalAuth::UnreadableAccounts.warn_if_any
else
  Rails.logger.debug 'Local auth disabled or missing credentials; skipping local admin seed.'
end

# Seed training topics
training_topics = [
  'Laser',
  'Sewing Machine',
  'Serger',
  'Embroidery Machine',
  'Dremel 3D45',
  'Ender 3',
  'Prusa',
  'Laminator',
  'Shaper',
  'General Shop',
  'Event Host',
  'Vinyl Cutter',
  'MPCNC Marlin',
  'Long Mill',
  'Member Management'
]

training_topics.each do |topic_name|
  TrainingTopic.find_or_create_by!(name: topic_name)
end

Rails.logger.debug { "Seeded #{training_topics.count} training topics." }

# Seed privileges and the starter roles that bundle them
Privilege.seed_defaults!
Rails.logger.debug { "Seeded #{Privilege.count} privileges." }

Role.seed_defaults!
Rails.logger.debug { "Seeded #{Role.count} roles." }

# Seed email templates
EmailTemplate.seed_defaults!
Rails.logger.debug { "Seeded #{EmailTemplate.count} email templates." }

# Seed payment processors
PaymentProcessor.seed_defaults!
Rails.logger.debug { "Seeded #{PaymentProcessor.count} payment processors." }

# Seed member sources
MemberSource.seed_defaults!
Rails.logger.debug { "Seeded #{MemberSource.count} member sources." }

# Seed nag settings
ReminderSetting.seed_defaults!
Rails.logger.debug { "Seeded #{ReminderSetting.count} reminder settings." }

# Seed incoming webhooks
IncomingWebhook.seed_defaults!
Rails.logger.debug { "Seeded #{IncomingWebhook.count} incoming webhooks." }

# Seed AI providers
AiProvider.seed_defaults!
Rails.logger.debug { "Seeded #{AiProvider.count} AI providers." }
