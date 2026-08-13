require 'test_helper'

class SensitiveFieldsTest < ActiveSupport::TestCase
  test 'user contact fields are encrypted while exact email lookup still works' do
    user = User.create!(
      full_name: 'Encrypted User',
      username: 'encrypted-user',
      email: 'Encrypted.User@Example.com',
      extra_emails: ['Alt.User@Example.com'],
      mailing_address: "123 Secret St\nPortland, OR",
      phone_number: '555-123-4567',
      active: true
    )

    user_row = raw_row('users', user.id)

    assert_equal 'Encrypted.User@Example.com', user.email
    assert_equal ['Alt.User@Example.com'], user.extra_emails
    assert_equal "123 Secret St\nPortland, OR", user.mailing_address
    assert_equal '555-123-4567', user.phone_number
    assert_no_plaintext user_row['email'], 'encrypted.user@example.com'
    assert_no_plaintext user_row['extra_emails'], 'Alt.User@Example.com'
    assert_no_plaintext user_row['mailing_address'], '123 Secret St'
    assert_no_plaintext user_row['phone_number'], '555-123-4567'
    assert_equal user, User.lookup_by_email('ENCRYPTED.USER@example.com')
    assert_equal user, User.by_any_email('alt.user@example.com').first
  end

  test 'integration raw attributes and service keys are encrypted at rest' do
    payment = PaypalPayment.create!(
      paypal_id: 'PAY-SENSITIVE-FIELDS',
      payer_email: 'payer-sensitive@example.com',
      payer_name: 'Sensitive Payer',
      raw_attributes: { 'payer_info' => { 'email_address' => 'payer-sensitive@example.com' } }
    )
    reader = RfidReader.create!(name: 'Encrypted Reader', key: 'a' * 32)
    provider = AiProvider.create!(name: 'Encrypted Provider', url: 'https://example.test', api_key: 'secret-ai-key')

    assert_equal 'payer-sensitive@example.com', payment.reload.payer_email
    assert_equal({ 'payer_info' => { 'email_address' => 'payer-sensitive@example.com' } }, payment.raw_attributes)
    assert_equal 'a' * 32, reader.reload.key
    assert_equal 'secret-ai-key', provider.reload.api_key

    assert_no_plaintext raw_row('paypal_payments', payment.id)['payer_email'], 'payer-sensitive@example.com'
    assert_no_plaintext raw_json('paypal_payments', payment.id, 'raw_attributes'), 'payer-sensitive@example.com'
    reader_row = raw_row('rfid_readers', reader.id)
    assert_no_plaintext reader_row['key'], 'a' * 32
    assert_no_plaintext reader_row['key_ciphertext'], 'a' * 32
    assert_no_plaintext raw_row('ai_providers', provider.id)['api_key'], 'secret-ai-key'
    assert_equal reader, RfidReader.lookup_by_key('a' * 32)
  end

  # Each encryption draws a fresh nonce, so a writer that always re-encodes would leave an
  # untouched record dirty and save it — dragging its after_save callbacks along.
  test 'assigning the value a record already holds does not dirty it' do
    user = User.create!(full_name: 'Settled User', username: 'settled-user', email: 'settled@example.com',
                        extra_emails: ['settled-alt@example.com'], phone_number: '555-000-1111')

    user.email = 'settled@example.com'
    user.extra_emails = ['settled-alt@example.com']
    user.phone_number = '555-000-1111'

    assert_not user.changed?, "expected no changes, got #{user.changes.keys.inspect}"
  end

  test 'assigning an identical json payload does not dirty the record' do
    payload = { 'payer_info' => { 'email_address' => 'idempotent@example.com' } }
    payment = PaypalPayment.create!(paypal_id: 'PAY-IDEMPOTENT', raw_attributes: payload)

    payment.raw_attributes = payload
    assert_not payment.changed?

    # A payload keyed by symbols is the same payload; JSON hands it back keyed by strings.
    payment.raw_attributes = { payer_info: { email_address: 'idempotent@example.com' } }
    assert_not payment.changed?
  end

  test 'normalizing an email during validation leaves an untouched record alone' do
    { PaypalPayment.create!(paypal_id: 'PAY-NORM', payer_email: 'norm@example.com') => 'payer_email',
      SheetEntry.create!(name: 'Norm', email: 'norm@example.com') => 'email',
      KofiPayment.create!(kofi_transaction_id: 'KOFI-NORM', email: 'norm@example.com') => 'email',
      RechargePayment.create!(recharge_id: 'RC-NORM', customer_email: 'norm@example.com') => 'customer_email' }
      .each do |record, field|
        record.valid?
        assert_not record.changed?, "#{record.class} dirtied #{field} during validation"
      end
  end

  test 'saving an unchanged record writes nothing' do
    user = User.create!(full_name: 'Quiet User', username: 'quiet-user', email: 'quiet@example.com')

    user.assign_attributes(email: 'quiet@example.com', full_name: 'Quiet User')

    updates = updates_issued { user.save! }

    assert_equal 0, updates
    assert_empty user.saved_changes
  end

  test 'a genuine change is still written' do
    user = User.create!(full_name: 'Moving User', username: 'moving-user', email: 'before@example.com')

    user.email = 'after@example.com'

    assert user.changed?

    updates = updates_issued { user.save! }

    assert_equal 1, updates
    assert_equal 'after@example.com', user.reload.email
  end

  # Recovering from a key change means assigning over ciphertext the current key cannot read.
  # Comparing the incoming value against it — the dirty check every writer does — is a
  # decryption, so the writers have to treat unreadable as unsettled rather than raise.
  test 'assigning over ciphertext encrypted under another key overwrites it' do
    user = User.create!(full_name: 'Orphaned User', username: 'orphaned-user', email: 'orphaned@example.com',
                        extra_emails: ['orphaned-alt@example.com'])
    user.update_columns(email: unreadable_ciphertext, extra_emails: [unreadable_ciphertext])

    user.reload
    user.email = 'orphaned@example.com'
    user.extra_emails = ['orphaned-alt@example.com']

    assert user.changed?
    assert_equal 'orphaned@example.com', user.email
    assert_equal ['orphaned-alt@example.com'], user.extra_emails
  end

  test 'assigning over a json payload encrypted under another key overwrites it' do
    payload = { 'payer_info' => { 'email_address' => 'orphaned@example.com' } }
    payment = PaypalPayment.create!(paypal_id: 'PAY-ORPHANED', raw_attributes: payload)
    payment.update_columns(raw_attributes: { SensitiveData::JSON_MARKER => 'not-ciphertext-from-this-key' })

    payment.reload
    payment.raw_attributes = payload

    assert payment.changed?
    assert_equal payload, payment.raw_attributes
  end

  test 'a column still holding plaintext is encrypted on assignment' do
    entry = SheetEntry.create!(name: 'Legacy', email: 'legacy@example.com')
    entry.update_columns(email: 'legacy@example.com')

    entry.email = 'legacy@example.com'

    assert entry.changed?
    assert SensitiveData.encrypted_string?(entry[:email])
    assert_equal 'legacy@example.com', entry.email
  end

  private

  def unreadable_ciphertext
    "#{SensitiveData::STRING_PREFIX}not-ciphertext-from-this-key"
  end

  def updates_issued(&block)
    count = 0
    subscription = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
      count += 1 if payload[:sql].to_s.match?(/\AUPDATE/i)
    end
    block.call
    count
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription)
  end

  def raw_row(table, id)
    ActiveRecord::Base.connection.exec_query("SELECT * FROM #{table} WHERE id = #{id.to_i}").first
  end

  def raw_json(table, id, column)
    ActiveRecord::Base.connection.select_value("SELECT #{column}::text FROM #{table} WHERE id = #{id.to_i}")
  end

  def assert_no_plaintext(raw_value, plaintext)
    assert raw_value.present?
    assert_not_includes raw_value.to_s, plaintext
  end
end
