module TrainingResources
  class LinkContentCheckJob < ApplicationJob
    queue_as :default

    def perform
      LinkContentChecker.call
    end
  end
end
