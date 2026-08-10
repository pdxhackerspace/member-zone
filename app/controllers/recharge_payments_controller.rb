class RechargePaymentsController < AuthenticatedController
  before_action -> { require_privilege!(:'payments.view') }, only: %i[index show]
  before_action -> { require_privilege!(:'payments.link') }, only: %i[link_user unlink toggle_dont_link]
  # See PaypalPaymentsController: sync, import/export, create_member and the connection
  # test are each a different authority from reconciling a payment.
  before_action -> { require_privilege!(:'payments.sync') }, only: :sync
  before_action -> { require_privilege!(:'payments.import_export') }, only: %i[export import]
  # See PaypalPaymentsController.
  before_action :require_admin!, only: %i[create_member test]

  def index
    # Start with all payments for counts
    all_payments = RechargePayment.all

    # Calculate counts
    @total_count = all_payments.count
    @linked_count = all_payments.where.not(user_id: nil).count
    # Unlinked excludes dont_link payments
    @unlinked_count = all_payments.where(user_id: nil, dont_link: false).count
    @dont_link_count = all_payments.where(dont_link: true).count

    # Build filtered query
    @payments = all_payments

    # Apply linked/unlinked filter
    case params[:linked]
    when 'yes'
      @payments = @payments.where.not(user_id: nil)
    when 'no'
      # Unlinked excludes dont_link payments
      @payments = @payments.where(user_id: nil, dont_link: false)
    when 'dont_link'
      @payments = @payments.where(dont_link: true)
    end

    @payments = @payments.search(params[:q]) if params[:q].present?

    @payments = @payments.includes(:user).ordered
    @payment_count = @payments.count
    @total_amount = @payments.sum(:amount)

    # Track filter state
    @filter_active = params[:linked].present? || params[:q].present?

    @pagy, @payments = pagy(@payments, limit: 100)
  end

  def show
    @payment = RechargePayment.find(params[:id])

    @customer_id = @payment.customer_id || extract_customer_id(@payment)
    @user_by_customer_id = nil
    @user_by_customer_id = User.where(recharge_customer_id: @customer_id.to_s).first if @customer_id.present?

    @all_users = User.ordered_by_display_name if @user_by_customer_id.nil?
  end

  def unlink
    @payment = RechargePayment.find(params[:id])
    customer_id = @payment.customer_id || extract_customer_id(@payment)
    user = @payment.user

    # Clear recharge_customer_id on the user so the auto-match breaks
    User.where(recharge_customer_id: customer_id.to_s).update_all(recharge_customer_id: nil) if customer_id.present?

    # Clear user_id on this payment and all sibling payments with the same customer_id
    @payment.update!(user_id: nil)
    RechargePayment.where(customer_id: customer_id, user_id: user&.id).update_all(user_id: nil) if customer_id.present?

    redirect_to recharge_payment_path(@payment),
                notice: "Unlinked from #{user&.display_name || 'member'}. " \
                        "All payments with customer ID #{customer_id} also unlinked."
  end

  def toggle_dont_link
    @payment = RechargePayment.find(params[:id])
    new_value = !@payment.dont_link
    @payment.update!(dont_link: new_value)

    notice = new_value ? "Payment marked as Don't Link." : "Payment unmarked as Don't Link."
    redirect_to recharge_payment_path(@payment), notice: notice
  end

  def create_member
    @payment = RechargePayment.find(params[:id])

    # Only allow creating member for unlinked payments
    if @payment.user_id.present?
      redirect_to recharge_payment_path(@payment), alert: 'Payment is already linked to a member.'
      return
    end

    # Create new user from payment data
    user = User.new(
      full_name: @payment.customer_name,
      email: @payment.customer_email,
      recharge_customer_id: @payment.customer_id,
      payment_type: 'recharge',
      membership_state: User.initial_membership_state
    )

    if user.save
      # Link the payment to the new user (this will trigger the callback)
      @payment.update!(user_id: user.id)
      redirect_to user_path(user), notice: "Created member #{user.display_name} and linked payment."
    else
      redirect_to recharge_payment_path(@payment),
                  alert: "Failed to create member: #{user.errors.full_messages.join(', ')}"
    end
  end

  def sync
    Recharge::PaymentSyncJob.perform_later
    Recharge::SubscriptionSyncJob.perform_later
    redirect_to recharge_payments_path, notice: 'Recharge payment and subscription sync has been scheduled.'
  end

  def test
    # Find payments that don't have a matching User by recharge_customer_id
    @unmatched_payments = []

    RechargePayment.find_each do |payment|
      customer_id = extract_customer_id(payment)
      next if customer_id.blank?

      # Check if any User has this customer_id as their recharge_customer_id
      matching_user = User.where(recharge_customer_id: customer_id.to_s).first

      unless matching_user
        @unmatched_payments << {
          payment: payment,
          email: payment.customer_email,
          name: payment.customer_name,
          customer_id: customer_id
        }
      end
    end

    @total_payments = RechargePayment.count
    @matched_count = @total_payments - @unmatched_payments.count
  end

  def link_user
    @payment = RechargePayment.find(params[:id])
    user = User.find(params[:user_id])

    customer_id = @payment.customer_id || extract_customer_id(@payment)

    if customer_id.present?
      # Link the payment to the user
      @payment.update!(user_id: user.id)

      # Explicitly link all other payments with the same customer_id
      # (The after_save callback should do this too, but being explicit to ensure it happens)
      linked_count = RechargePayment.where(customer_id: customer_id, user_id: nil)
                                    .update_all(user_id: user.id)

      # Update the user's recharge_customer_id if not already set
      user.update_column(:recharge_customer_id, customer_id.to_s) if user.recharge_customer_id.blank?

      # Update user's payment status
      user.on_recharge_payment_linked(@payment)

      extra_msg = if linked_count.positive?
                    " Also linked #{linked_count} other payment#{'s' if linked_count != 1} with the same customer ID."
                  else
                    ''
                  end
      redirect_to recharge_payment_path(@payment),
                  notice: "Linked to #{user.display_name}.#{extra_msg}"
    else
      redirect_to recharge_payment_path(@payment), alert: 'Cannot link: payment has no customer ID.'
    end
  end

  def export
    # Export all Recharge payments as complete JSON backup
    payments_data = RechargePayment.all.map do |payment|
      payment_data = {
        recharge_id: payment.recharge_id,
        status: payment.status,
        amount: payment.amount&.to_s, # Convert BigDecimal to string for JSON
        currency: payment.currency,
        processed_at: payment.processed_at&.iso8601,
        charge_type: payment.charge_type,
        customer_email: payment.customer_email,
        customer_name: payment.customer_name,
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
              disposition: 'attachment; filename=recharge_payments_backup_' \
                           "#{Time.current.strftime('%Y%m%d_%H%M%S')}.json"
  end

  def import
    if params[:file].blank?
      redirect_to recharge_payments_path, alert: 'No file provided.'
      return
    end

    begin
      json_data = JSON.parse(params[:file].read)

      unless json_data.is_a?(Hash) && json_data['payments'].is_a?(Array)
        redirect_to recharge_payments_path, alert: 'Invalid JSON format. Expected object with "payments" array.'
        return
      end

      imported_count = 0
      updated_count = 0
      skipped_count = 0
      errors = []

      ActiveRecord::Base.transaction do
        json_data['payments'].each do |payment_data|
          # Find or initialize payment by recharge_id
          payment = RechargePayment.find_or_initialize_by(recharge_id: payment_data['recharge_id'])

          # Update all attributes
          payment.status = payment_data['status']

          # Handle amount conversion (can be string or number)
          payment.amount = BigDecimal(payment_data['amount'].to_s) if payment_data['amount'].present?

          payment.currency = payment_data['currency']

          # Parse timestamps
          payment.processed_at = Time.zone.parse(payment_data['processed_at']) if payment_data['processed_at'].present?

          payment.charge_type = payment_data['charge_type']
          payment.customer_email = payment_data['customer_email']
          payment.customer_name = payment_data['customer_name']
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
          errors << "Payment #{payment_data['recharge_id']}: #{e.message}"
          Rails.logger.error("Failed to import Recharge payment #{payment_data['recharge_id']}: #{e.message}")
        end
      end

      # Record CSV import in processor
      processor = PaymentProcessor.for('recharge')
      processor.record_csv_import!

      notice_parts = ["Import complete: #{imported_count} imported, #{updated_count} updated"]
      notice_parts << "#{skipped_count} skipped" if skipped_count.positive?
      notice = notice_parts.join(', ')

      if errors.any?
        notice += ". Errors: #{errors.first(5).join('; ')}"
        notice += " (#{errors.count - 5} more)" if errors.count > 5
      end

      redirect_to recharge_payments_path, notice: notice
    rescue JSON::ParserError => e
      redirect_to recharge_payments_path, alert: "Invalid JSON: #{e.message}"
    rescue StandardError => e
      redirect_to recharge_payments_path, alert: "Import failed: #{e.message}"
    end
  end

  private

  def extract_customer_id(payment)
    return nil if payment.raw_attributes.blank?

    payment.raw_attributes.dig('customer', 'id') ||
      payment.raw_attributes['customer_id']
  end
end
