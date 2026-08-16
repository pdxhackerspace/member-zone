require 'faraday'

module Recharge
  # HTTP client for the Recharge payments API.
  # Supports fetching charges (payments) and subscriptions with pagination.
  class Client
    CHARGES_ENDPOINT = '/charges'.freeze
    SUBSCRIPTIONS_ENDPOINT = '/subscriptions'.freeze
    MAX_LIMIT = 250
    MAX_PAGES = 1000

    def initialize(api_key: RechargeConfig.settings.api_key,
                   base_url: RechargeConfig.settings.api_base_url)
      @api_key = api_key
      @base_url = base_url&.delete_suffix('/')
    end

    # Fetch subscriptions updated within the given time window.
    # Returns an array of normalized subscription hashes.
    def subscriptions(start_time: 2.days.ago, end_time: Time.current, status: nil)
      raise ArgumentError, 'Recharge API key missing' unless RechargeConfig.enabled?

      params = {
        updated_at_min: start_time.utc.iso8601,
        updated_at_max: end_time.utc.iso8601,
        limit: MAX_LIMIT
      }
      params[:status] = status if status.present?

      Rails.logger.info(
        '[Recharge::Client] Fetching subscriptions from ' \
        "#{params[:updated_at_min]} to #{params[:updated_at_max]}"
      )
      paginate(SUBSCRIPTIONS_ENDPOINT, 'subscriptions', params) { |sub| normalize_subscription(sub) }
    end

    def charges(start_time: default_start_time, end_time: Time.current)
      raise ArgumentError, 'Recharge API key missing' unless RechargeConfig.enabled?

      params = {
        updated_at_min: start_time.utc.iso8601,
        updated_at_max: end_time.utc.iso8601,
        limit: MAX_LIMIT
      }

      Rails.logger.info(
        '[Recharge::Client] Fetching charges from ' \
        "#{params[:updated_at_min]} to #{params[:updated_at_max]}"
      )
      paginate(CHARGES_ENDPOINT, 'charges', params) { |charge| normalize_charge(charge) }
    end

    private

    # Generic paginated fetch for any Recharge API list endpoint.
    # Yields each raw item to the block for normalization.
    def paginate(endpoint, key, params, &)
      results = []
      page = 1

      loop do
        response = connection.get(endpoint, params.merge(page: page))
        payload = JSON.parse(response.body)
        items = Array(payload[key])

        Rails.logger.debug { "[Recharge::Client] #{endpoint} page #{page}: #{items.size} items" }
        break if items.empty?

        results.concat(items.map(&))

        break unless more_pages?(payload, items.size)

        page += 1
        break if page > MAX_PAGES
      end

      Rails.logger.info("[Recharge::Client] Finished #{endpoint}. Total: #{results.size}")
      results
    end

    def more_pages?(payload, count)
      meta = payload['meta'] || {}
      return true if meta['next'].present?

      count >= MAX_LIMIT
    end

    def default_start_time
      days = RechargeConfig.settings.transactions_lookback_days
      days = 30 if days <= 0
      Time.current - days.days
    end

    def connection
      @connection ||= Faraday.new(url: @base_url) do |faraday|
        faraday.request :url_encoded
        faraday.response :raise_error
        faraday.adapter Faraday.default_adapter
        faraday.headers['X-Recharge-Access-Token'] = @api_key
        faraday.headers['Accept'] = 'application/json'
      end
    end

    def normalize_charge(charge)
      customer = charge['customer'] || {}
      billing = charge['billing_address'] || {}
      name = customer['first_name'].to_s.presence || billing['first_name']
      last = customer['last_name'].to_s.presence || billing['last_name']
      full_name = [name, last].compact_blank.join(' ')

      # Redact billing_address and shipping_address in raw_attributes
      redacted_charge = charge.deep_dup
      redacted_charge['billing_address'] = 'REDACTED' if redacted_charge.key?('billing_address')
      redacted_charge['shipping_address'] = 'REDACTED' if redacted_charge.key?('shipping_address')

      {
        recharge_id: charge['id'].to_s,
        status: charge['status'],
        amount: charge.dig('amount', 'amount') || charge['total_price'],
        currency: charge.dig('amount', 'currency') || charge['currency'],
        processed_at: parse_time(charge['processed_at']) || parse_time(charge['created_at']),
        charge_type: charge['type'],
        customer_id: (customer['id'] || charge['customer_id']).to_s,
        customer_email: customer['email'] || charge['email'],
        customer_name: full_name.presence || customer['billing_first_name'],
        raw_attributes: redacted_charge
      }
    end

    def normalize_subscription(sub)
      {
        recharge_subscription_id: sub['id'].to_s,
        customer_id: sub['customer_id'].to_s,
        email: sub['email'],
        status: sub['status'],
        product_title: sub['product_title'],
        price: sub['price'],
        cancelled_at: parse_time(sub['cancelled_at']),
        cancellation_reason: sub['cancellation_reason'],
        created_at: parse_time(sub['created_at']),
        updated_at: parse_time(sub['updated_at'])
      }
    end

    def parse_time(value)
      return if value.blank?

      Time.zone.parse(value)
    rescue ArgumentError
      nil
    end
  end
end
