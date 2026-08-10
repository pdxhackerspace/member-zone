class PaypalPaymentsController < AuthenticatedController
  include Pagy::Method

  before_action -> { require_privilege!(:'payments.view') }, only: %i[index show unmatched_subjects]
  before_action -> { require_privilege!(:'payments.link') }, only: %i[link_user unlink toggle_dont_link]
  # Reconciling payments is not the same authority as pulling from the processor, moving
  # data in or out, or minting a member record. Those belong to payments.sync,
  # payments.import_export and members.create, none of which this phase enforces; `test`
  # opens a live connection to PayPal and has no catalog key at all.
  before_action -> { require_privilege!(:'payments.sync') }, only: :sync
  before_action -> { require_privilege!(:'payments.import_export') }, only: %i[export import]
  # create_member is member creation, and test exercises the live processor credentials.
  before_action :require_admin!, only: %i[create_member test]

  def index
    # Determine if we're showing unmatched payments
    @show_unmatched = params[:show_unmatched] == 'true'

    # Base scope depends on matched/unmatched toggle
    base_payments = @show_unmatched ? PaypalPayment.not_matching_plan : PaypalPayment.matching_plan

    # Calculate counts (only for the current matched/unmatched view)
    @total_count = base_payments.count
    @linked_count = base_payments.where.not(user_id: nil).count
    @unlinked_count = base_payments.where(user_id: nil, dont_link: false).count
    @dont_link_count = base_payments.where(dont_link: true).count

    # Count of unmatched payments (always calculated for the button)
    @unmatched_plan_count = PaypalPayment.not_matching_plan.count

    # Build filtered query
    @payments = base_payments

    # Apply linked/unlinked filter
    case params[:linked]
    when 'yes'
      @payments = @payments.where.not(user_id: nil)
    when 'no'
      @payments = @payments.where(user_id: nil, dont_link: false)
    when 'dont_link'
      @payments = @payments.where(dont_link: true)
    end

    @payments = @payments.search(params[:q]) if params[:q].present?

    @payments = @payments.ordered
    @payment_count = @payments.count
    @total_amount = @payments.sum(:amount)

    @pagy, @payments = pagy(@payments.includes(:user), limit: 100)

    # Track filter state
    @filter_active = params[:linked].present? || params[:q].present?
  end

  def unmatched_subjects
    # Get unique transaction subjects from payments that don't match any plan
    unmatched = PaypalPayment.not_matching_plan
    @subjects = unmatched.map { |p| extract_subject(p) }.compact.uniq.sort
  end

  def show
    @payment = PaypalPayment.find(params[:id])

    @user_by_paypal_account_id = nil
    @user_by_paypal_account_id = User.where(paypal_account_id: @payment.payer_id).first if @payment.payer_id.present?

    @all_users = User.ordered_by_display_name if @user_by_paypal_account_id.nil?
  end

  def link_user
    @payment = PaypalPayment.find(params[:id])
    user = User.find(params[:user_id])

    if @payment.payer_id.present?
      # Link the payment to the user
      @payment.update!(user_id: user.id)

      # Explicitly link all other payments with the same payer_id
      # (The after_save callback should do this too, but being explicit to ensure it happens)
      linked_count = PaypalPayment.where(payer_id: @payment.payer_id, user_id: nil)
                                  .update_all(user_id: user.id)

      # Update the user's paypal_account_id if not already set
      user.update_column(:paypal_account_id, @payment.payer_id) if user.paypal_account_id.blank?

      # Update user's payment status
      user.on_paypal_payment_linked(@payment)

      extra_msg = if linked_count.positive?
                    " Also linked #{linked_count} other payment#{'s' if linked_count != 1} with the same payer ID."
                  else
                    ''
                  end
      redirect_to paypal_payment_path(@payment),
                  notice: "Linked to #{user.display_name}.#{extra_msg}"
    else
      redirect_to paypal_payment_path(@payment), alert: 'Cannot link: payment has no payer ID.'
    end
  end

  def unlink
    @payment = PaypalPayment.find(params[:id])
    payer_id = @payment.payer_id
    user = @payment.user

    # Clear paypal_account_id on the user so the auto-match breaks
    User.where(paypal_account_id: payer_id).update_all(paypal_account_id: nil) if payer_id.present?

    # Clear user_id on this payment and all sibling payments with the same payer_id
    @payment.update!(user_id: nil)
    PaypalPayment.where(payer_id: payer_id, user_id: user&.id).update_all(user_id: nil) if payer_id.present?

    redirect_to paypal_payment_path(@payment),
                notice: "Unlinked from #{user&.display_name || 'member'}. " \
                        "All payments with payer ID #{payer_id} also unlinked."
  end

  def toggle_dont_link
    @payment = PaypalPayment.find(params[:id])
    new_value = !@payment.dont_link
    @payment.update!(dont_link: new_value)

    notice = new_value ? "Payment marked as Don't Link." : "Payment unmarked as Don't Link."
    redirect_to paypal_payment_path(@payment), notice: notice
  end

  def create_member
    @payment = PaypalPayment.find(params[:id])

    # Only allow creating member for unlinked payments
    if @payment.user_id.present?
      redirect_to paypal_payment_path(@payment), alert: 'Payment is already linked to a member.'
      return
    end

    # Create new user from payment data
    user = User.new(
      full_name: @payment.payer_name,
      email: @payment.payer_email,
      paypal_account_id: @payment.payer_id,
      payment_type: 'paypal',
      membership_state: User.initial_membership_state
    )

    if user.save
      # Link the payment to the new user (this will trigger the callback)
      @payment.update!(user_id: user.id)
      redirect_to user_path(user), notice: "Created member #{user.display_name} and linked payment."
    else
      redirect_to paypal_payment_path(@payment),
                  alert: "Failed to create member: #{user.errors.full_messages.join(', ')}"
    end
  end

  def sync
    Paypal::PaymentSyncJob.perform_later
    redirect_to paypal_payments_path, notice: 'PayPal payment sync has been scheduled.'
  end

  private

  def extract_subject(payment)
    return nil if payment.raw_attributes.blank?

    raw = payment.raw_attributes
    raw.dig('transaction_info', 'transaction_subject') ||
      raw.dig('cart_info', 'item_details', 0, 'item_name') ||
      nil
  end

  public

  def test
    # Only consider payments for $40 (with small tolerance for decimal precision)
    @payments40 = PaypalPayment.where(amount: 39.99..40.01)

    # Find payments that don't have a matching User by paypal_account_id
    @unmatched_payments = []

    @payments40.find_each do |payment|
      next if payment.payer_id.blank?

      # Check if any User has this payer_id as their paypal_account_id
      matching_user = User.where(paypal_account_id: payment.payer_id).first

      unless matching_user
        @unmatched_payments << {
          payment: payment,
          email: payment.payer_email,
          name: payment.payer_name
        }
      end
    end

    @total40_payments = @payments40.count
    @matched_count = @total40_payments - @unmatched_payments.count
  end

  def export
    # Export all PayPal payments as complete JSON backup
    payments_data = PaypalPayment.all.map do |payment|
      payment_data = {
        paypal_id: payment.paypal_id,
        status: payment.status,
        amount: payment.amount&.to_s, # Convert BigDecimal to string for JSON
        currency: payment.currency,
        transaction_time: payment.transaction_time&.iso8601,
        transaction_type: payment.transaction_type,
        payer_email: payment.payer_email,
        payer_name: payment.payer_name,
        payer_id: payment.payer_id,
        raw_attributes: payment.raw_attributes,
        last_synced_at: payment.last_synced_at&.iso8601,
        created_at: payment.created_at.iso8601,
        updated_at: payment.updated_at.iso8601
      }

      # Export user relationship by identifier
      if payment.user
        payment_data[:user_email] = payment.user.email
        payment_data[:user_authentik_id] = payment.user.authentik_id
      end

      payment_data
    end

    export_data = {
      version: '1.0',
      exported_at: Time.current.iso8601,
      count: payments_data.count,
      payments: payments_data
    }

    send_data JSON.pretty_generate(export_data),
              type: 'application/json',
              disposition: "attachment; filename=paypal_payments_backup_#{Time.current.strftime('%Y%m%d_%H%M%S')}.json"
  end

  def import
    if params[:file].blank?
      redirect_to paypal_payments_path, alert: 'No file provided.'
      return
    end

    begin
      json_data = JSON.parse(params[:file].read)

      unless json_data.is_a?(Hash) && json_data['payments'].is_a?(Array)
        redirect_to paypal_payments_path, alert: 'Invalid JSON format. Expected object with "payments" array.'
        return
      end

      imported_count = 0
      updated_count = 0
      skipped_count = 0
      errors = []

      ActiveRecord::Base.transaction do
        json_data['payments'].each do |payment_data|
          # Find or initialize payment by paypal_id
          payment = PaypalPayment.find_or_initialize_by(paypal_id: payment_data['paypal_id'])

          # Update all attributes
          payment.status = payment_data['status']

          # Handle amount conversion (can be string or number)
          payment.amount = BigDecimal(payment_data['amount'].to_s) if payment_data['amount'].present?

          payment.currency = payment_data['currency']

          # Parse timestamps
          if payment_data['transaction_time'].present?
            payment.transaction_time = Time.zone.parse(payment_data['transaction_time'])
          end

          payment.transaction_type = payment_data['transaction_type']
          payment.payer_email = payment_data['payer_email']
          payment.payer_name = payment_data['payer_name']
          payment.payer_id = payment_data['payer_id']
          payment.raw_attributes = payment_data['raw_attributes'] || {}

          if payment_data['last_synced_at'].present?
            payment.last_synced_at = Time.zone.parse(payment_data['last_synced_at'])
          end

          # Restore user relationship
          if payment_data['user_email'].present? || payment_data['user_authentik_id'].present?
            user = nil

            # Try to find by email first
            user = User.lookup_by_email(payment_data['user_email']) if payment_data['user_email'].present?

            # Try to find by authentik_id if not found
            if user.nil? && payment_data['user_authentik_id'].present?
              user = User.find_by(authentik_id: payment_data['user_authentik_id'])
            end

            payment.user = user if user
          end

          was_new = payment.new_record?

          # Save the payment first
          payment.save!

          # Restore timestamps after save (Rails allows setting these directly)
          if payment_data['created_at'].present?
            payment.update_column(:created_at, Time.zone.parse(payment_data['created_at']))
          end
          if payment_data['updated_at'].present?
            payment.update_column(:updated_at, Time.zone.parse(payment_data['updated_at']))
          end

          if was_new
            imported_count += 1
          else
            updated_count += 1
          end
        rescue StandardError => e
          skipped_count += 1
          errors << "Payment #{payment_data['paypal_id']}: #{e.message}"
          Rails.logger.error("Failed to import PayPal payment #{payment_data['paypal_id']}: #{e.message}")
        end
      end

      # Record CSV import in processor
      processor = PaymentProcessor.for('paypal')
      processor.record_csv_import!

      notice_parts = ["Import complete: #{imported_count} imported, #{updated_count} updated"]
      notice_parts << "#{skipped_count} skipped" if skipped_count.positive?
      notice = notice_parts.join(', ')

      if errors.any?
        notice += ". Errors: #{errors.first(5).join('; ')}"
        notice += " (#{errors.count - 5} more)" if errors.count > 5
      end

      redirect_to paypal_payments_path, notice: notice
    rescue JSON::ParserError => e
      redirect_to paypal_payments_path, alert: "Invalid JSON: #{e.message}"
    rescue StandardError => e
      redirect_to paypal_payments_path, alert: "Import failed: #{e.message}"
    end
  end
end
