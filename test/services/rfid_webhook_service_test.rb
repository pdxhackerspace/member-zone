require 'test_helper'

class RfidWebhookServiceTest < ActiveSupport::TestCase
  setup do
    reset_rfid_webhook_state!
    @rfid = unique_rfid
    @pin = '1234'
  end

  teardown do
    reset_rfid_webhook_state!
  end

  test 'a stored scan comes back with its reader' do
    RfidWebhookService.store(@rfid, @pin, 7, 'Front Door Reader')

    scan = RfidWebhookService.retrieve(@rfid)

    assert_equal @rfid, scan[:rfid]
    assert_equal @pin, scan[:pin]
    assert_equal 7, scan[:reader_id]
    assert_equal 'Front Door Reader', scan[:reader_name]
  end

  test 'storing normalizes the fob id so it is found under either form' do
    RfidWebhookService.store('  ABC,0042  ', @pin)

    assert_not_nil RfidWebhookService.retrieve('ABC,42')
  end

  test 'a blank fob id is not stored' do
    assert_nil RfidWebhookService.store('   ', @pin)
  end

  # Claiming

  test 'claiming returns the scan and names the holder' do
    started = 1.minute.ago
    RfidWebhookService.store(@rfid, @pin)

    scan = RfidWebhookService.claim_recent(started, 'token-a')

    assert_equal @rfid, scan[:rfid]
    assert RfidWebhookService.claimed_by?(@rfid, 'token-a')
  end

  # The wait page polls every two seconds, so the same session asks over and over and must keep
  # getting the same answer rather than losing its own claim.
  test 'polling with the same token keeps returning the same scan' do
    started = 1.minute.ago
    RfidWebhookService.store(@rfid, @pin)

    first = RfidWebhookService.claim_recent(started, 'token-a')
    second = RfidWebhookService.claim_recent(started, 'token-a')

    assert_equal first[:rfid], second[:rfid]
  end

  # The reason this class exists. Before claims, any browser sitting on the login page picked up
  # the next scan anyone made at the door and got to guess at that member's PIN.
  test 'a scan already claimed is not handed to a second session' do
    started = 1.minute.ago
    RfidWebhookService.store(@rfid, @pin)
    RfidWebhookService.claim_recent(started, 'token-a')

    assert_nil RfidWebhookService.claim_recent(started, 'token-b')
    assert_not RfidWebhookService.claimed_by?(@rfid, 'token-b')
  end

  test 'a scan made before the browser started waiting is ignored' do
    RfidWebhookService.store(@rfid, @pin)

    assert_nil RfidWebhookService.claim_recent(1.minute.from_now, 'token-a')
  end

  test 'claiming without a token claims nothing' do
    started = 1.minute.ago
    RfidWebhookService.store(@rfid, @pin)

    assert_nil RfidWebhookService.claim_recent(started, nil)
    assert_nil RfidWebhookService.claim_recent(started, '')
  end

  test 'the newest scan is the one claimed' do
    started = 1.hour.ago
    older = unique_rfid
    RfidWebhookService.store(older, '1111')
    travel 30.seconds do
      RfidWebhookService.store(@rfid, @pin)

      assert_equal @rfid, RfidWebhookService.claim_recent(started, 'token-a')[:rfid]
    end
  end

  test 'a fresh scan of the same fob can be claimed by a different session' do
    started = 1.minute.ago
    RfidWebhookService.store(@rfid, @pin)
    RfidWebhookService.claim_recent(started, 'token-a')

    # The member walks away, someone else starts a sign-in and badges the same fob.
    RfidWebhookService.store(@rfid, @pin)

    assert_not_nil RfidWebhookService.claim_recent(started, 'token-b')
  end

  test 'claimed_by? is false for a scan nobody has claimed' do
    RfidWebhookService.store(@rfid, @pin)

    assert_not RfidWebhookService.claimed_by?(@rfid, 'token-a')
  end

  test 'claimed_by? is false for a fob that was never scanned' do
    assert_not RfidWebhookService.claimed_by?(unique_rfid, 'token-a')
  end

  # PIN verification

  test 'the right PIN verifies once and consumes the scan' do
    RfidWebhookService.store(@rfid, @pin)

    assert_equal :verified, RfidWebhookService.verify_and_consume(@rfid, @pin)
    assert_nil RfidWebhookService.retrieve(@rfid), 'the scan must not be reusable'
    assert_equal :no_pending_scan, RfidWebhookService.verify_and_consume(@rfid, @pin)
  end

  test 'a wrong PIN is refused but leaves the scan in place to try again' do
    RfidWebhookService.store(@rfid, @pin)

    assert_equal :invalid_pin, RfidWebhookService.verify_and_consume(@rfid, '9999')
    assert_not_nil RfidWebhookService.retrieve(@rfid)
    assert_equal 1, RfidWebhookService.failed_attempts(@rfid)
  end

  # The whole point of the change: a four-digit code with unlimited guesses inside a five-minute
  # window is 10,000 possibilities and no obstacle at all.
  test 'the scan is thrown away after the last wrong PIN' do
    RfidWebhookService.store(@rfid, @pin)

    (RfidWebhookService::MAX_PIN_ATTEMPTS - 1).times do |attempt|
      assert_equal :invalid_pin, RfidWebhookService.verify_and_consume(@rfid, '9999'),
                   "guess #{attempt + 1} should still be allowed"
    end

    assert_equal :too_many_attempts, RfidWebhookService.verify_and_consume(@rfid, '9999')
    assert_nil RfidWebhookService.retrieve(@rfid)
    assert_not RfidWebhookService.claimed_by?(@rfid, 'token-a')
  end

  test 'the right PIN is no use once the attempts are spent' do
    RfidWebhookService.store(@rfid, @pin)
    RfidWebhookService::MAX_PIN_ATTEMPTS.times { RfidWebhookService.verify_and_consume(@rfid, '9999') }

    assert_equal :no_pending_scan, RfidWebhookService.verify_and_consume(@rfid, @pin)
  end

  test 'a correct PIN part way through resets nothing and simply works' do
    RfidWebhookService.store(@rfid, @pin)
    2.times { RfidWebhookService.verify_and_consume(@rfid, '9999') }

    assert_equal :verified, RfidWebhookService.verify_and_consume(@rfid, @pin)
  end

  # A member who exhausts their guesses has to be able to badge in again, so a new scan clears the
  # count. Otherwise the fob would be locked out for the rest of the window.
  test 'scanning again clears the failed guesses' do
    RfidWebhookService.store(@rfid, @pin)
    2.times { RfidWebhookService.verify_and_consume(@rfid, '9999') }
    assert_equal 2, RfidWebhookService.failed_attempts(@rfid)

    RfidWebhookService.store(@rfid, @pin)

    assert_equal 0, RfidWebhookService.failed_attempts(@rfid)
  end

  test 'verifying a fob with no pending scan says so' do
    assert_equal :no_pending_scan, RfidWebhookService.verify_and_consume(unique_rfid, '1234')
  end

  test 'a PIN of the wrong length is refused rather than raising' do
    RfidWebhookService.store(@rfid, @pin)

    assert_equal :invalid_pin, RfidWebhookService.verify_and_consume(@rfid, '')
    assert_equal :invalid_pin, RfidWebhookService.verify_and_consume(@rfid, '123456789')
    assert_equal :invalid_pin, RfidWebhookService.verify_and_consume(@rfid, nil)
  end

  test 'discarding forgets the scan, the claim, and the guesses' do
    started = 1.minute.ago
    RfidWebhookService.store(@rfid, @pin)
    RfidWebhookService.claim_recent(started, 'token-a')
    RfidWebhookService.verify_and_consume(@rfid, '9999')

    RfidWebhookService.discard(@rfid)

    assert_nil RfidWebhookService.retrieve(@rfid)
    assert_not RfidWebhookService.claimed_by?(@rfid, 'token-a')
    assert_equal 0, RfidWebhookService.failed_attempts(@rfid)
  end

  test 'a stored scan expires on its own' do
    RfidWebhookService.store(@rfid, @pin)

    ttl = RfidWebhookService.redis.ttl(RfidWebhookService.redis_key(@rfid))

    assert_operator ttl, :>, 0
    assert_operator ttl, :<=, RfidWebhookService::EXPIRATION_TIME.to_i
  end
end
