# SPDX-FileCopyrightText: 2025 John Romkey
#
# SPDX-License-Identifier: CC0-1.0

# The short-lived handoff between a badge scan at the door and the browser finishing the
# sign-in. A reader posts the fob id and the PIN typed on its keypad to the RFID webhook; the
# login page is waiting for a scan, claims it, and asks for the PIN again to prove the person
# at the keyboard is the person who badged in.
#
# Two properties matter and neither is obvious from the happy path:
#
#   * A scan may be claimed by exactly one browser session. Otherwise any browser sitting on
#     the login page picks up the next scan anyone makes at the door and gets to guess at that
#     member's PIN.
#   * A PIN gets a small, fixed number of guesses. A four-digit code with unlimited attempts
#     inside the five-minute window is 10,000 possibilities and no obstacle at all.
class RfidWebhookService
  REDIS_KEY_PREFIX = 'rfid_webhook:'.freeze
  CLAIM_KEY_PREFIX = 'rfid_webhook_claim:'.freeze
  ATTEMPTS_KEY_PREFIX = 'rfid_webhook_attempts:'.freeze
  EXPIRATION_TIME = 5.minutes
  MAX_PIN_ATTEMPTS = 5

  # Keys are read with SCAN rather than KEYS. The login page polls every two seconds, and KEYS
  # walks the whole keyspace while blocking every other client — including Sidekiq, which
  # shares this Redis.
  SCAN_BATCH_SIZE = 100

  class << self
    def store(rfid_code, pin_code, reader_id = nil, reader_name = nil)
      rfid_code = RfidNormalizer.call(rfid_code)
      return nil if rfid_code.blank?

      data = {
        rfid: rfid_code,
        pin: pin_code,
        reader_id: reader_id,
        reader_name: reader_name,
        created_at: Time.current.to_i
      }.to_json

      redis.setex(redis_key(rfid_code), EXPIRATION_TIME.to_i, data)
      # A fresh scan is a fresh start: it clears the claim a previous scan of the same fob left
      # behind (or no other browser could claim this one) and the failed-guess count (or a
      # member locked out at the door could not simply badge in again).
      redis.del(claim_key(rfid_code), attempts_key(rfid_code))
      rfid_code
    rescue Redis::CannotConnectError, Redis::TimeoutError
      Rails.logger.warn('Redis unavailable in RfidWebhookService.store')
      nil
    end

    def retrieve(rfid_code)
      data = redis.get(redis_key(rfid_code))
      return nil if data.nil?

      JSON.parse(data).symbolize_keys
    rescue JSON::ParserError
      nil
    rescue Redis::CannotConnectError, Redis::TimeoutError
      Rails.logger.warn('Redis unavailable in RfidWebhookService.retrieve')
      nil
    end

    # Claims the most recent scan this session is allowed to have, and returns it.
    #
    # `claim_token` identifies the browser session asking. The claim is taken with SET NX, so
    # of two sessions polling in the same instant exactly one wins and the loser goes on
    # waiting rather than quietly attaching itself to someone else's badge. Re-asking with the
    # same token returns the same scan, because the page polls.
    def claim_recent(since_time, claim_token)
      return nil if claim_token.blank?

      recent_scans(since_time).each do |scan|
        return scan if claim(scan[:rfid], claim_token)
      end

      nil
    rescue Redis::CannotConnectError, Redis::TimeoutError
      Rails.logger.warn('Redis unavailable in RfidWebhookService.claim_recent')
      nil
    end

    # Whether this session still holds the claim on a scan. Checked again when the PIN is
    # submitted, so a stale session[:pending_rfid] cannot be replayed against a later scan of
    # the same fob by someone else.
    def claimed_by?(rfid_code, claim_token)
      return false if rfid_code.blank? || claim_token.blank?

      holder = redis.get(claim_key(rfid_code))
      return false if holder.nil?

      ActiveSupport::SecurityUtils.secure_compare(holder, claim_token)
    rescue Redis::CannotConnectError, Redis::TimeoutError
      Rails.logger.warn('Redis unavailable in RfidWebhookService.claimed_by?')
      false
    end

    # Checks the PIN and reports what happened, rather than returning a bare boolean, because
    # the caller has to tell "wrong PIN, try again" apart from "that scan is gone now".
    #
    # Returns :verified, :invalid_pin, :too_many_attempts, or :no_pending_scan.
    def verify_and_consume(rfid_code, pin_code)
      data = retrieve(rfid_code)
      return :no_pending_scan if data.nil?

      if ActiveSupport::SecurityUtils.secure_compare(data[:pin].to_s, pin_code.to_s)
        discard(rfid_code)
        return :verified
      end

      attempts = record_failed_attempt(rfid_code)

      # A nil count means Redis would not tell us how many guesses have been made. Throwing the
      # scan away is the safe reading; the member can badge in again.
      if attempts.nil? || attempts >= MAX_PIN_ATTEMPTS
        Rails.logger.warn("RFID PIN attempts exhausted for #{rfid_code}; discarding the pending scan")
        discard(rfid_code)
        :too_many_attempts
      else
        :invalid_pin
      end
    rescue Redis::CannotConnectError, Redis::TimeoutError
      Rails.logger.warn('Redis unavailable in RfidWebhookService.verify_and_consume')
      :no_pending_scan
    end

    # Forgets a scan completely: the scan itself, whoever claimed it, and the guesses made
    # against it.
    def discard(rfid_code)
      redis.del(redis_key(rfid_code), claim_key(rfid_code), attempts_key(rfid_code))
    rescue Redis::CannotConnectError, Redis::TimeoutError
      Rails.logger.warn('Redis unavailable in RfidWebhookService.discard')
      nil
    end

    def failed_attempts(rfid_code)
      redis.get(attempts_key(rfid_code)).to_i
    rescue Redis::CannotConnectError, Redis::TimeoutError
      0
    end

    def redis_key(rfid_code)
      "#{REDIS_KEY_PREFIX}#{normalized(rfid_code)}"
    end

    def redis
      @redis ||= Redis.new(url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/0'))
    end

    private

    def claim_key(rfid_code)
      "#{CLAIM_KEY_PREFIX}#{normalized(rfid_code)}"
    end

    def attempts_key(rfid_code)
      "#{ATTEMPTS_KEY_PREFIX}#{normalized(rfid_code)}"
    end

    def normalized(rfid_code)
      RfidNormalizer.call(rfid_code).to_s.downcase
    end

    # True when this token now holds the claim — either because it just took it, or because it
    # already held it and is polling again.
    def claim(rfid_code, claim_token)
      key = claim_key(rfid_code)
      return true if redis.set(key, claim_token, nx: true, ex: EXPIRATION_TIME.to_i)

      claimed_by?(rfid_code, claim_token)
    end

    def record_failed_attempt(rfid_code)
      key = attempts_key(rfid_code)
      count = redis.incr(key)
      # The counter has to outlive the scan it guards, or expiring first would hand back a fresh
      # set of guesses inside the same five minutes. Re-setting it on each failure only pushes
      # the expiry further out, which is the safe direction.
      redis.expire(key, EXPIRATION_TIME.to_i)
      count
    rescue Redis::CannotConnectError, Redis::TimeoutError
      nil
    end

    # Scans still live, newest first. Anything older than the moment the browser started
    # waiting is ignored, so a page left open does not pick up a scan from before it asked.
    def recent_scans(since_time)
      keys = []
      redis.scan_each(match: "#{REDIS_KEY_PREFIX}*", count: SCAN_BATCH_SIZE) { |key| keys << key }
      return [] if keys.empty?

      redis.mget(*keys).filter_map { |raw| parse_scan(raw, since_time) }
           .sort_by { |scan| -scan[:created_at] }
    end

    def parse_scan(raw, since_time)
      return nil if raw.nil?

      scan = JSON.parse(raw).symbolize_keys
      return nil if scan[:rfid].blank? || scan[:created_at].blank?
      return nil if Time.zone.at(scan[:created_at]) < since_time

      scan
    rescue JSON::ParserError, ArgumentError, TypeError
      nil
    end
  end
end
