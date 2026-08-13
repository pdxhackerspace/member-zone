module LocalAuth
  # A local sign-in account written before DATABASE_FIELD_ENCRYPTION_KEY and
  # EMAIL_LOOKUP_HMAC_KEY were set explicitly — or under a key that has since changed — keeps
  # working right up until the keys move. Then the stored digest stops matching, the address
  # stops decrypting, and the sign-in form answers "Invalid email or password" with nothing
  # in the log to say why. Reporting them turns that into a diagnosable failure.
  class UnreadableAccounts
    class << self
      def ids
        LocalAccount.unreadable.map(&:id)
      end

      def any?
        LocalAccount.unreadable.any?
      end

      def warn_if_any
        found = ids
        Rails.logger.warn(message(found)) if found.any?
        found
      end

      def prune!
        LocalAccount.where(id: ids).destroy_all.map(&:id)
      end

      def message(found = ids)
        "#{found.size} local sign-in account(s) (id #{found.join(', ')}) hold an address " \
          'encrypted under a different DATABASE_FIELD_ENCRYPTION_KEY than the one now configured, ' \
          'so they can no longer authenticate anyone. Run `rails local_auth:provision` to ' \
          'create a working account, then `rails local_auth:prune_unreadable` to remove these.'
      end
    end
  end
end
