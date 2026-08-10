module Membership
  # Advances the clock on membership states. Most transitions are driven by an event —
  # a payment arrives, an admin bans someone — but several end on a deadline instead:
  # a new member's grace period runs out, a paid-through date passes. Nothing happens on
  # its own the day those deadlines land, so this job runs daily and materializes them.
  #
  # Access checks use #active?, which resolves deadlines on read, so the door stays
  # correct between runs. What this job does is make the stored state and the cached
  # `active` column match reality for queries, reports, reminders, and state-entry email.
  class TickJob < ApplicationJob
    queue_as :default

    def perform
      expired = 0
      reconciled = 0

      candidates.find_each do |user|
        result = StateTick.call(user)
        case result.status
        when :expired
          log_expiry(result)
          expired += 1
        when :reconciled
          reconciled += 1
        end
      end

      Rails.logger.info("[Membership::TickJob] expired #{expired}, reconciled #{reconciled}")
      { expired: expired, reconciled: reconciled }
    end

    private

    def candidates
      User.non_service_accounts
    end

    def log_expiry(result)
      Rails.logger.info("[Membership::TickJob] #{result.user.display_name} (id #{result.user.id}): " \
                        "#{result.from_state} -> #{result.to_state}")
    end
  end
end
