# Delivers mail that is not worth retrying, and gives up quietly when it cannot.
#
# Action Mailer's default job leaves a failed delivery to the queue adapter's retries, which on
# Sidekiq's defaults means roughly 25 attempts over three weeks. That is right for mail a member is
# waiting on. It is wrong for a diagnostic: an admin who pressed "Send test" and moved on should not
# receive a copy days later, most likely after editing the template they were testing.
#
# The failure is not swallowed silently. By the time it reaches here +ApplicationMailer+ has already
# recorded it on +MailerDeliveryMonitor+, so the mailer health check sees it, and written a
# +send_failed+ entry visible under the mail log's Failed filter.
class SingleAttemptMailDeliveryJob < ActionMailer::MailDeliveryJob
  discard_on StandardError do |job, error|
    mailer, mail_method, = job.arguments
    Rails.logger.warn(
      "[SingleAttemptMailDelivery] #{mailer}##{mail_method} failed and will not be retried — " \
      "#{error.class}: #{error.message}"
    )
  end
end
