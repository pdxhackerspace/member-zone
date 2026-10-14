module ParkingNotices
  # What a parking-notice operation did. +error+ is nil on success, otherwise a symbol naming
  # the rule that refused it (:invalid means the notice carries validation errors). Front ends
  # turn the symbol into a flash message or an API error; the services never know which.
  Result = Data.define(:notice, :error, :newly_added, :job_id, :message) do
    def initialize(notice:, error: nil, newly_added: [], job_id: nil, message: nil)
      super
    end

    def success?
      error.nil?
    end
  end
end
