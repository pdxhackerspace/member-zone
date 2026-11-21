module TrainingResources
  # The Reminders page "Send now" button. It skips the interval; the daily job does not.
  class SendDigest
    def self.call
      UpdateDigest.call(force: true)
    end
  end
end
