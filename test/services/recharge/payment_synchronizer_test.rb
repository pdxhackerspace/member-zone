require 'test_helper'

module Recharge
  class PaymentSynchronizerTest < ActiveSupport::TestCase
    setup do
      @processed_at = Time.zone.local(2026, 10, 27, 12, 0, 0)
      @user = User.create!(
        authentik_id: "recharge-sync-#{SecureRandom.hex(4)}",
        full_name: 'Recharge Sync Member',
        payment_type: 'recharge',
        membership_state: 'inactive_member',
        membership_plan: membership_plans(:monthly_standard),
        recharge_customer_id: "cust-#{SecureRandom.hex(4)}"
      )
      @user.update_columns(membership_state_entered_at: Time.zone.local(2026, 10, 1, 0, 0, 0))
    end

    test 're-fetching a stored charge does not apply it to membership again' do
      payment = stored_charge
      @user.update_columns(recharge_most_recent_payment_date: nil)

      travel_to Time.zone.local(2026, 10, 28, 6, 0, 0) do
        sync_charges([charge_attrs(payment.recharge_id, @processed_at)])
      end

      @user.reload
      assert_equal 'inactive_member', @user.membership_state
      assert_equal @processed_at.to_i, @user.recharge_most_recent_payment_date.to_i
    end

    test 'a new charge is applied to membership' do
      travel_to Time.zone.local(2026, 10, 28, 6, 0, 0) do
        sync_charges([charge_attrs("ch-new-#{SecureRandom.hex(4)}", Time.current)])
      end

      assert_equal 'current_member', @user.reload.membership_state
    end

    private

    def sync_charges(charges)
      with_recharge_enabled { PaymentSynchronizer.new(client: FakeClient.new(charges)).call }
    end

    def with_recharge_enabled
      settings = RechargeConfig.settings
      previous = settings.api_key
      settings.api_key = 'test-key'
      yield
    ensure
      settings.api_key = previous
    end

    # Linked with update_columns so the after_save callback does not apply the charge.
    # The sync under test is a later re-fetch of a payment the member already has.
    def stored_charge
      payment = RechargePayment.create!(
        recharge_id: "ch-stored-#{SecureRandom.hex(4)}",
        status: 'SUCCESS',
        amount: 40,
        currency: 'USD',
        processed_at: @processed_at,
        raw_attributes: { 'customer' => { 'id' => @user.recharge_customer_id } }
      )
      payment.update_columns(user_id: @user.id)
      payment
    end

    def charge_attrs(recharge_id, processed_at)
      {
        status: 'SUCCESS',
        recharge_id: recharge_id,
        amount: 40,
        currency: 'USD',
        processed_at: processed_at,
        charge_type: 'recurring',
        customer_email: nil,
        customer_name: @user.full_name,
        customer_id: @user.recharge_customer_id,
        raw_attributes: { 'customer' => { 'id' => @user.recharge_customer_id } }
      }
    end

    class FakeClient
      def initialize(charges)
        @charges = charges
      end

      def charges(start_time:)
        start_time ? @charges : []
      end
    end
  end
end
