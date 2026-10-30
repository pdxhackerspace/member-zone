module CashPayments
  # What a newly recorded cash payment does: files it in the payment event ledger, applies
  # it to the member as a payment, and notes it in their journal. The cash payments page and
  # "Mark dues received" both record cash this way, so a member marked paid has a payment
  # behind it like everyone else.
  class Recorder
    def self.sync_payment_event!(cash_payment)
      event = cash_payment.payment_events.find_or_initialize_by(
        source: 'cash',
        external_id: cash_payment.identifier,
        event_type: 'payment'
      )
      event.assign_attributes(
        user: cash_payment.user,
        amount: cash_payment.amount,
        currency: 'USD',
        occurred_at: cash_payment.paid_on&.beginning_of_day || Time.current,
        details: "Cash payment - #{cash_payment.membership_plan&.name || 'Unknown plan'}"
      )
      event.save!
    end

    def initialize(cash_payment, actor:)
      @cash_payment = cash_payment
      @user = cash_payment.user
      @actor = actor
    end

    def call
      self.class.sync_payment_event!(@cash_payment)
      old_dues_status = @user.dues_status
      apply_to_member!
      journal!(old_dues_status)
    end

    private

    def apply_to_member!
      current_dues_due_at = @user.dues_due_at
      updates = @user.apply_payment_updates(
        { time: @cash_payment.paid_on, amount: @cash_payment.amount },
        { payment_type: 'cash', last_payment_date: @cash_payment.paid_on },
        billing_plan: @cash_payment.membership_plan,
        first_seen: true
      )
      keep_later_dues_due_at!(updates, current_dues_due_at)
      @user.update!(updates) if updates.present?
    end

    # A cash payment recorded late must not pull back a due date a later payment set.
    def keep_later_dues_due_at!(updates, current_dues_due_at)
      return unless updates.key?(:dues_due_at)

      new_dues_due_at = updates[:dues_due_at]
      if new_dues_due_at.blank?
        updates.delete(:dues_due_at)
        return
      end

      return if current_dues_due_at.blank?
      return if new_dues_due_at > current_dues_due_at

      updates.delete(:dues_due_at)
    end

    def journal!(old_dues_status)
      Journal.create!(
        user: @user,
        actor_user: @actor,
        action: 'membership_status_changed',
        changed_at: Time.current,
        changes_json: {
          'dues_status' => { 'from' => old_dues_status, 'to' => @user.reload.dues_status },
          'note' => "Cash payment of $#{format('%.2f', @cash_payment.amount)} recorded"
        }
      )
    end
  end
end
