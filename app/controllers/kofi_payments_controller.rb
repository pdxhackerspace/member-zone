class KofiPaymentsController < AuthenticatedController
  include Pagy::Method

  require 'csv'

  before_action -> { require_privilege!(:'payments.view') }, only: %i[index show]
  before_action -> { require_privilege!(:'payments.link') }, only: :link_user
  # Bulk data movement belongs to payments.import_export, which this phase does not enforce.
  before_action -> { require_privilege!(:'payments.import_export') }, only: %i[import_csv export import]

  def index
    all_payments = KofiPayment.all

    # Ko-Fi has no don't-link flag, so a supporter is either tied to a member or still waiting
    # for someone to tie them.
    @total_count = all_payments.count
    @linked_count = all_payments.where.not(user_id: nil).count
    @unlinked_count = all_payments.where(user_id: nil).count

    @payments = all_payments
    case params[:linked]
    when 'yes'
      @payments = @payments.where.not(user_id: nil)
    when 'no'
      @payments = @payments.where(user_id: nil)
    end

    @payments = @payments.search(params[:q]) if params[:q].present?

    @payments = @payments.includes(:user).ordered
    @payment_count = @payments.count
    @total_amount = @payments.sum(:amount)

    @filter_active = params[:linked].present? || params[:q].present?

    @pagy, @payments = pagy(@payments, limit: 100)
  end

  def show
    @payment = KofiPayment.find(params[:id])

    # Try to find user by email
    @user_by_email = nil
    @user_by_email = User.by_any_email(@payment.email).first if @payment.email.present?

    # Get all users for the selection dropdown (if no match found)
    @all_users = User.ordered_by_display_name if @user_by_email.nil?
  end

  def link_user
    @payment = KofiPayment.find(params[:id])
    user = User.find(params[:user_id])

    updates = {}

    # Link payment to user regardless of email availability
    @payment.update!(user: user)

    # Copy email from payment if user doesn't have one
    if @payment.email.present?
      if user.email.blank?
        updates[:email] = @payment.email
      elsif user.email.downcase != @payment.email.downcase
        extra_emails = user.extra_emails || []
        unless extra_emails.map(&:downcase).include?(@payment.email.downcase)
          extra_emails << @payment.email
          updates[:extra_emails] = extra_emails
        end
      end
    end

    # Set payment_type to 'kofi'
    updates[:payment_type] = 'kofi' if user.payment_type != 'kofi'

    # Find the most recent payment for this user (by email or user_id)
    most_recent_payment = if @payment.email.present?
                            KofiPayment.by_email(@payment.email)
                                       .where.not(timestamp: nil)
                                       .order(timestamp: :desc)
                                       .first
                          else
                            KofiPayment.where(user_id: user.id)
                                       .where.not(timestamp: nil)
                                       .order(timestamp: :desc)
                                       .first
                          end

    if most_recent_payment&.timestamp
      updates = user.apply_payment_updates(
        { time: most_recent_payment.timestamp, amount: most_recent_payment.amount },
        updates,
        first_seen: most_recent_payment == @payment
      )
    end

    user.update!(updates) if updates.present?

    redirect_to kofi_payment_path(@payment),
                notice: "Linked to #{user.display_name}."
  end

  def import_csv
    if params[:file].blank?
      redirect_to kofi_payments_path, alert: 'No file provided.'
      return
    end

    begin
      csv_content = params[:file].read.force_encoding('UTF-8')
      csv_data = CSV.parse(csv_content, headers: true)

      imported_count = 0
      updated_count = 0
      skipped_count = 0
      errors = []

      ActiveRecord::Base.transaction do
        csv_data.each do |row|
          # Ko-Fi CSV columns vary, but typically include:
          # Date, From, Type, Amount, Currency, Status, Message, Email, Ko-fi Transaction ID, Tier Name
          # New export includes: TransactionId, TransactionType, BuyerEmail, DateTime (UTC)
          transaction_id = row['Ko-fi Transaction ID'] || row['Transaction ID'] ||
                           row['TransactionId'] || row['kofi_transaction_id']

          if transaction_id.blank?
            skipped_count += 1
            errors << "Row missing transaction ID: #{row.to_h.inspect[0..100]}"
            next
          end

          payment = KofiPayment.find_or_initialize_by(kofi_transaction_id: transaction_id)

          # Parse amount (remove currency symbols if present)
          amount_str = row['Amount'] || row['Received'] || row['amount']
          if amount_str.present?
            # Remove currency symbols and commas
            amount_str = amount_str.to_s.gsub(/[^\d.]/, '')
            payment.amount = BigDecimal(amount_str) if amount_str.present?
          end

          payment.currency = row['Currency'] || row['currency'] || 'USD'
          payment.from_name = row['From'] || row['from_name'] || row['Name']
          payment.email = row['Email'] || row['BuyerEmail'] || row['email']
          payment.payment_type = row['Type'] || row['TransactionType'] || row['type'] || row['Payment Type']
          payment.message = row['Message'] || row['message']
          payment.tier_name = row['Tier Name'] || row['Item'] || row['tier_name'] || row['Tier']
          payment.status = row['Status'] || row['status'] || 'completed'

          # Parse date
          date_str = row['Date'] || row['date'] || row['Timestamp'] || row['DateTime (UTC)']
          payment.timestamp = parse_kofi_timestamp(date_str) if date_str.present?

          # Store original CSV row in raw_attributes
          payment.raw_attributes = row.to_h
          payment.last_synced_at = Time.current

          was_new = payment.new_record?
          payment.save!

          if was_new
            imported_count += 1
            PaymentEvent.find_or_create_by!(source: 'kofi', external_id: payment.kofi_transaction_id,
                                            event_type: 'payment') do |pe|
              pe.user = payment.user
              pe.amount = payment.amount
              pe.currency = payment.currency || 'USD'
              pe.occurred_at = payment.timestamp || payment.created_at
              pe.details = "Ko-Fi #{payment.payment_type || 'payment'} from #{payment.from_name || payment.email}"
              pe.kofi_payment = payment
            end
          else
            updated_count += 1
          end
        rescue StandardError => e
          skipped_count += 1
          errors << "Row #{row['Ko-fi Transaction ID'] || 'unknown'}: #{e.message}"
          Rails.logger.error("Failed to import Ko-Fi payment: #{e.message}")
        end
      end

      # Record CSV import in processor
      processor = PaymentProcessor.for('kofi')
      processor.record_csv_import!

      notice_parts = ["Import complete: #{imported_count} imported, #{updated_count} updated"]
      notice_parts << "#{skipped_count} skipped" if skipped_count.positive?
      notice = notice_parts.join(', ')

      if errors.any?
        notice += ". Errors: #{errors.first(5).join('; ')}"
        notice += " (#{errors.count - 5} more)" if errors.count > 5
      end

      redirect_to kofi_payments_path, notice: notice
    rescue CSV::MalformedCSVError => e
      redirect_to kofi_payments_path, alert: "Invalid CSV: #{e.message}"
    rescue StandardError => e
      redirect_to kofi_payments_path, alert: "Import failed: #{e.message}"
    end
  end

  def export
    # Export all Ko-Fi payments as complete JSON backup
    payments_data = KofiPayment.all.map do |payment|
      payment_data = {
        kofi_transaction_id: payment.kofi_transaction_id,
        message_id: payment.message_id,
        status: payment.status,
        amount: payment.amount&.to_s,
        currency: payment.currency,
        timestamp: payment.timestamp&.iso8601,
        payment_type: payment.payment_type,
        from_name: payment.from_name,
        email: payment.email,
        message: payment.message,
        url: payment.url,
        is_public: payment.is_public,
        is_subscription_payment: payment.is_subscription_payment,
        is_first_subscription_payment: payment.is_first_subscription_payment,
        tier_name: payment.tier_name,
        shop_items: payment.shop_items,
        raw_attributes: payment.raw_attributes,
        last_synced_at: payment.last_synced_at&.iso8601,
        created_at: payment.created_at.iso8601,
        updated_at: payment.updated_at.iso8601
      }

      if payment.user
        payment_data[:user_email] = payment.user.email
        payment_data[:user_authentik_id] = payment.user.authentik_id
      end

      if payment.sheet_entry
        payment_data[:sheet_entry_email] = payment.sheet_entry.email
        payment_data[:sheet_entry_name] = payment.sheet_entry.name
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
              disposition: "attachment; filename=kofi_payments_backup_#{Time.current.strftime('%Y%m%d_%H%M%S')}.json"
  end

  def import
    if params[:file].blank?
      redirect_to kofi_payments_path, alert: 'No file provided.'
      return
    end

    begin
      json_data = JSON.parse(params[:file].read)

      unless json_data.is_a?(Hash) && json_data['payments'].is_a?(Array)
        redirect_to kofi_payments_path, alert: 'Invalid JSON format. Expected object with "payments" array.'
        return
      end

      imported_count = 0
      updated_count = 0
      skipped_count = 0
      errors = []

      ActiveRecord::Base.transaction do
        json_data['payments'].each do |payment_data|
          payment = KofiPayment.find_or_initialize_by(kofi_transaction_id: payment_data['kofi_transaction_id'])

          payment.message_id = payment_data['message_id']
          payment.status = payment_data['status']

          payment.amount = BigDecimal(payment_data['amount'].to_s) if payment_data['amount'].present?

          payment.currency = payment_data['currency']

          payment.timestamp = Time.zone.parse(payment_data['timestamp']) if payment_data['timestamp'].present?

          payment.payment_type = payment_data['payment_type']
          payment.from_name = payment_data['from_name']
          payment.email = payment_data['email']
          payment.message = payment_data['message']
          payment.url = payment_data['url']
          payment.is_public = payment_data['is_public']
          payment.is_subscription_payment = payment_data['is_subscription_payment']
          payment.is_first_subscription_payment = payment_data['is_first_subscription_payment']
          payment.tier_name = payment_data['tier_name']
          payment.shop_items = payment_data['shop_items'] || []
          payment.raw_attributes = payment_data['raw_attributes'] || {}

          if payment_data['last_synced_at'].present?
            payment.last_synced_at = Time.zone.parse(payment_data['last_synced_at'])
          end

          # Restore user relationship
          if payment_data['user_email'].present? || payment_data['user_authentik_id'].present?
            user = nil

            user = User.lookup_by_email(payment_data['user_email']) if payment_data['user_email'].present?

            if user.nil? && payment_data['user_authentik_id'].present?
              user = User.find_by(authentik_id: payment_data['user_authentik_id'])
            end

            payment.user = user if user
          end

          # Restore sheet_entry relationship
          if payment_data['sheet_entry_email'].present? || payment_data['sheet_entry_name'].present?
            sheet_entry = nil

            if payment_data['sheet_entry_email'].present?
              sheet_entry = SheetEntry.by_email(payment_data['sheet_entry_email']).first
            end

            if sheet_entry.nil? && payment_data['sheet_entry_name'].present?
              sheet_entry = SheetEntry.find_by(name: payment_data['sheet_entry_name'])
            end

            payment.sheet_entry = sheet_entry if sheet_entry
          end

          was_new = payment.new_record?
          payment.save!

          if payment_data['created_at'].present?
            payment.update_column(:created_at, Time.zone.parse(payment_data['created_at']))
          end
          if payment_data['updated_at'].present?
            payment.update_column(:updated_at, Time.zone.parse(payment_data['updated_at']))
          end

          if was_new
            imported_count += 1
            PaymentEvent.find_or_create_by!(source: 'kofi', external_id: payment.kofi_transaction_id,
                                            event_type: 'payment') do |pe|
              pe.user = payment.user
              pe.amount = payment.amount
              pe.currency = payment.currency || 'USD'
              pe.occurred_at = payment.timestamp || payment.created_at
              pe.details = "Ko-Fi #{payment.payment_type || 'payment'} from #{payment.from_name || payment.email}"
              pe.kofi_payment = payment
            end
          else
            updated_count += 1
          end
        rescue StandardError => e
          skipped_count += 1
          errors << "Payment #{payment_data['kofi_transaction_id']}: #{e.message}"
          Rails.logger.error("Failed to import Ko-Fi payment #{payment_data['kofi_transaction_id']}: #{e.message}")
        end
      end

      notice_parts = ["Import complete: #{imported_count} imported, #{updated_count} updated"]
      notice_parts << "#{skipped_count} skipped" if skipped_count.positive?
      notice = notice_parts.join(', ')

      if errors.any?
        notice += ". Errors: #{errors.first(5).join('; ')}"
        notice += " (#{errors.count - 5} more)" if errors.count > 5
      end

      redirect_to kofi_payments_path, notice: notice
    rescue JSON::ParserError => e
      redirect_to kofi_payments_path, alert: "Invalid JSON: #{e.message}"
    rescue StandardError => e
      redirect_to kofi_payments_path, alert: "Import failed: #{e.message}"
    end
  end

  def parse_kofi_timestamp(value)
    return nil if value.blank?

    value = value.to_s.strip
    if value.match?(%r{\A\d{1,2}/\d{1,2}/\d{4}\s+\d{1,2}:\d{2}\z})
      Time.use_zone('UTC') do
        Time.zone.strptime(value, '%m/%d/%Y %H:%M')
      end
    else
      Time.zone.parse(value)
    end
  rescue ArgumentError, TypeError
    nil
  end
end
