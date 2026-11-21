module TrainingResources
  class UpdateDigestJob < ApplicationJob
    queue_as :default

    def perform
      UpdateDigest.call
    end
  end
end
