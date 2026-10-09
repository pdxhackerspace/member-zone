module Credentials
  # Daily backstop for member-standing syncs, failed revocations and stuck issues.
  class ReconcileJob < ApplicationJob
    queue_as :default

    def perform
      Reconciler.call
    end
  end
end
