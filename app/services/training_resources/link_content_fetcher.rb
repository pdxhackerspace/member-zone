require 'faraday'

module TrainingResources
  # Downloads one link. Conditional headers can skip a download, but a 200 is
  # always handed back so the checker can hash the body itself: a header is a
  # hint that something changed, not proof of what changed.
  class LinkContentFetcher
    MAX_BYTES = 2.megabytes
    MAX_REDIRECTS = 5
    REDIRECT_STATUSES = [301, 302, 303, 307, 308].freeze

    Result = Struct.new(:status, :body, :content_type, :etag, :last_modified, :error, keyword_init: true)

    def self.call(url, headers: {}, http: nil, resolver: nil)
      new(url, headers: headers, http: http, resolver: resolver).call
    end

    def initialize(url, headers:, http:, resolver:)
      @url = url
      @headers = headers
      @http = http
      @resolver = resolver
    end

    def call
      interpret(fetch(TextFragments::SourceUrlNormalizer.call(@url)))
    rescue OutboundUrlGuard::Forbidden, Error => e
      failure(e.message)
    rescue Faraday::Error, URI::InvalidURIError, Resolv::ResolvError, SocketError => e
      failure(e.message.to_s.truncate(200))
    end

    private

    def fetch(url)
      headers = @headers.dup
      MAX_REDIRECTS.times do
        OutboundUrlGuard.validate!(url, resolver: @resolver || Resolv)
        response = request(url, headers)
        location = redirect_location(response, url)
        return response if location.nil?

        url = location
        headers = {}
      end
      raise Error, 'too many redirects'
    end

    def interpret(response)
      if response.status == 304
        return Result.new(status: :not_modified, etag: header(response, 'etag'),
                          last_modified: header(response, 'last-modified'))
      end
      return failure("Could not read (#{response.status})") unless response.status.to_i.between?(200, 299)

      body = response.body.to_s
      return Result.new(status: :too_large) if body.bytesize > MAX_BYTES

      Result.new(status: :ok, body: body, content_type: header(response, 'content-type'),
                 etag: header(response, 'etag'), last_modified: header(response, 'last-modified'))
    end

    def request(url, headers)
      return @http.get(url, headers) if @http

      client.get(url) { |req| headers.each { |key, value| req.headers[key] = value } }
    end

    def redirect_location(response, current)
      return nil unless REDIRECT_STATUSES.include?(response.status.to_i)

      location = header(response, 'location')
      raise Error, 'redirect without a location' if location.blank?

      URI.join(current, location).to_s
    end

    def header(response, name)
      headers = response.headers || {}
      headers[name] || headers[name.downcase] || headers[name.capitalize]
    end

    def failure(message)
      Result.new(status: :error, error: message.to_s.truncate(255))
    end

    def client
      @client ||= Faraday.new do |builder|
        builder.adapter Faraday.default_adapter
        builder.options.timeout = 20
        builder.options.open_timeout = 5
        builder.headers['User-Agent'] = 'MemberZone TrainingLinkCheck/1.0'
      end
    end

    class Error < StandardError; end
  end
end
