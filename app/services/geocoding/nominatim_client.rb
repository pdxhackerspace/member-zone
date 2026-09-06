require 'json'

module Geocoding
  class NominatimClient
    ENDPOINT = 'https://nominatim.openstreetmap.org'.freeze

    def initialize(
      base_url: ENV.fetch('GEOCODING_BASE_URL', ENDPOINT),
      user_agent: ENV.fetch('GEOCODING_USER_AGENT', default_user_agent),
      email: ENV.fetch('GEOCODING_CONTACT_EMAIL', nil)
    )
      @connection = Faraday.new(url: base_url) do |faraday|
        faraday.headers['User-Agent'] = user_agent
      end
      @email = email
    end

    def geocode(address)
      return nil if address.blank?

      response = @connection.get('/search', request_params(address))
      raise "Geocoding failed with HTTP #{response.status}" unless response.success?

      first_result = JSON.parse(response.body).first
      return nil if first_result.blank?

      {
        latitude: first_result.fetch('lat').to_d,
        longitude: first_result.fetch('lon').to_d
      }
    end

    private

    def request_params(address)
      params = {
        q: address,
        format: 'jsonv2',
        limit: 1
      }
      params[:email] = @email if @email.present?
      params
    end

    # Nominatim's usage policy requires an identifying User-Agent.
    def default_user_agent
      "MemberZone/#{AppVersion.semver}"
    end
  end
end
