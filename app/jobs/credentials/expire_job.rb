module Credentials
  # Daily, after Membership::TickJob: warns about credentials expiring within a week and marks
  # the ones past their date as expired.
  class ExpireJob < ApplicationJob
    queue_as :default

    def perform
      Expirer.call
    end
  end
end
