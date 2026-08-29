require 'sidekiq'
require 'sidekiq-cron'

redis_url = ENV.fetch('REDIS_URL', 'redis://redis:6379/0')

Sidekiq.configure_server do |config|
  config.redis = { url: redis_url }

  # Plain queue names — no prefix needed since this app has its own Redis instance.
  # Do NOT use ActiveJob queue_name_prefix; it double-prefixes with sidekiq-cron.
  config.queues = %w[default mailers]

  # Schedule recurring jobs (only runs in Sidekiq server process)
  # Note: When using active_job: true, don't specify a prefixed queue name -
  # ActiveJob will apply its own prefix automatically

  # PayPal Payment Sync - Daily at 6am
  Sidekiq::Cron::Job.create(
    name: 'PayPal Payment Sync - Daily at 6am',
    cron: '0 6 * * *',
    class: 'Paypal::PaymentSyncJob',
    active_job: true
  )

  # Recharge Payment Sync - Daily at 6am
  Sidekiq::Cron::Job.create(
    name: 'Recharge Payment Sync - Daily at 6am',
    cron: '0 6 * * *',
    class: 'Recharge::PaymentSyncJob',
    active_job: true
  )

  # Recharge Subscription Sync - Every 6 hours (safety net for missed webhooks)
  Sidekiq::Cron::Job.create(
    name: 'Recharge Subscription Sync - Every 6 hours',
    cron: '0 */6 * * *',
    class: 'Recharge::SubscriptionSyncJob',
    active_job: true
  )

  # Access Controller Ping - Every 10 minutes
  Sidekiq::Cron::Job.create(
    name: 'Access Controller Ping - Every 10 minutes',
    cron: '*/10 * * * *',
    class: 'AccessControllerPingJob',
    active_job: true
  )

  # AI / Ollama health - Every 10 minutes
  Sidekiq::Cron::Job.create(
    name: 'AI Ollama Health Check - Every 10 minutes',
    cron: '*/10 * * * *',
    class: 'AiOllamaHealthCheckJob',
    active_job: true
  )

  # Printer health - Every 10 minutes
  Sidekiq::Cron::Job.create(
    name: 'Printer Health Check - Every 10 minutes',
    cron: '*/10 * * * *',
    class: 'PrinterHealthCheckJob',
    active_job: true
  )

  # Access Controller Backup - Daily at 1am
  Sidekiq::Cron::Job.create(
    name: 'Access Controller Backup - Daily at 1am',
    cron: '0 1 * * *',
    class: 'AccessControllerBackupJob',
    active_job: true
  )

  # Membership State Tick - Daily at 4am, before the payment syncs and reminders so
  # they see today's states rather than yesterday's.
  Sidekiq::Cron::Job.create(
    name: 'Membership State Tick - Daily at 4am',
    cron: '0 4 * * *',
    class: 'Membership::TickJob',
    active_job: true
  )

  # Parking Notice Expiration - Daily at 7am
  Sidekiq::Cron::Job.create(
    name: 'Parking Notice Expiration - Daily at 7am',
    cron: '0 7 * * *',
    class: 'ParkingNoticeExpirationJob',
    active_job: true
  )

  # Slack Signup Reminder - Daily at 7am
  Sidekiq::Cron::Job.create(
    name: 'Slack Signup Reminder - Daily at 7am',
    cron: '0 7 * * *',
    class: 'SlackSignupReminderJob',
    active_job: true
  )

  # Application Link Reminder - Daily at 7:15am
  Sidekiq::Cron::Job.create(
    name: 'Application Link Reminder - Daily at 7:15am',
    cron: '15 7 * * *',
    class: 'ApplicationLinkReminderJob',
    active_job: true
  )

  # Overdue Payment Reminder - Daily at 7:30am (cadence enforced per member)
  Sidekiq::Cron::Job.create(
    name: 'Overdue Payment Reminder - Daily at 7:30am',
    cron: '30 7 * * *',
    class: 'PaymentOverdueReminderJob',
    active_job: true
  )

  # Orientation Reminder - Daily at 7:45am (cadence enforced per member)
  Sidekiq::Cron::Job.create(
    name: 'Orientation Reminder - Daily at 7:45am',
    cron: '45 7 * * *',
    class: 'OrientationReminderJob',
    active_job: true
  )

  # Lapsed Member Access Reminder - Daily at 8:05am
  Sidekiq::Cron::Job.create(
    name: 'Lapsed Member Access Reminder - Daily at 8:05am',
    cron: '5 8 * * *',
    class: 'LapsedAccessReminderJob',
    active_job: true
  )

  # Login Link Expiration - Daily at 8am
  Sidekiq::Cron::Job.create(
    name: 'Login Link Expiration - Daily at 8am',
    cron: '0 8 * * *',
    class: 'LoginLinkExpirationJob',
    active_job: true
  )

  # Membership Application Reminders - Daily at 9am
  Sidekiq::Cron::Job.create(
    name: 'Membership Application Reminders - Daily at 9am',
    cron: '0 9 * * *',
    class: 'MembershipApplicationReminderJob',
    active_job: true
  )

  # Admin Dashboard Urgent Digest - Daily at 9:15am, after morning reminders so queued mail
  # is included in mailer health checks and admins see the day's reminder backlog.
  Sidekiq::Cron::Job.find('Admin Dashboard Urgent Digest - Daily at 7am')&.destroy
  Sidekiq::Cron::Job.create(
    name: 'Admin Dashboard Urgent Digest - Daily at 9:15am',
    cron: '15 9 * * *',
    class: 'AdminDashboardUrgentDigestJob',
    active_job: true
  )

  # Membership Application AI Feedback Retry - Every 30 minutes
  Sidekiq::Cron::Job.create(
    name: 'Membership Application AI Feedback Retry - Every 30 minutes',
    cron: '*/30 * * * *',
    class: 'MembershipApplicationAiFeedbackRetryJob',
    active_job: true
  )

  # Message Trash Cleanup - Daily at 5am
  Sidekiq::Cron::Job.create(
    name: 'Message Trash Cleanup - Daily at 5am',
    cron: '0 5 * * *',
    class: 'MessageTrashCleanupJob',
    active_job: true
  )

  # Member Geocoding - Hourly
  Sidekiq::Cron::Job.create(
    name: 'Member Geocoding - Hourly',
    cron: '0 * * * *',
    class: 'MemberGeocodingJob',
    active_job: true
  )
end

Sidekiq.configure_client do |config|
  config.redis = { url: redis_url }
end
