require 'net/http'

module TrainingResources
  # Downloads one link. Conditional headers can skip a download, but a 200 is
  # always handed back so the checker can hash the body itself: a header is a
  # hint that something changed, not proof of what changed. The socket connects
  # to the address the guard already accepted, and the body is capped while it
  # is read.
  class LinkContentFetcher
    MAX_BYTES = 2.megabytes
    MAX_REDIRECTS = 5
    REDIRECT_STATUSES = [301, 302, 303, 307, 308].freeze
    USER_AGENT = 'MemberZone TrainingLinkCheck/1.0'.freeze

    Result = Struct.new(:status, :body, :content_type, :etag, :last_modified, :error, keyword_init: true)
    HttpResponse = Struct.new(:status, :body, :headers, keyword_init: true)

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
    rescue TooLarge
      Result.new(status: :too_large)
    rescue OutboundUrlGuard::Forbidden, Error => e
      failure(e.message)
    rescue Timeout::Error, IOError, SystemCallError, URI::InvalidURIError, Resolv::ResolvError => e
      failure(e.message.to_s.truncate(200))
    end

    private

    def fetch(url)
      headers = @headers.dup
      MAX_REDIRECTS.times do
        resolved = OutboundUrlGuard.resolve!(url, resolver: @resolver || Resolv)
        response = request(resolved, headers)
        location = redirect_location(response, resolved.uri.to_s)
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

    def request(resolved, headers)
      return @http.get(resolved.uri.to_s, headers) if @http

      download(resolved, headers)
    end

    def download(resolved, headers)
      uri = resolved.uri
      result = nil
      Net::HTTP.start(uri.host, uri.port, **http_options(uri, resolved.address)) do |http|
        http.request(build_request(uri, headers)) { |response| result = read_response(response) }
      end
      result
    end

    def http_options(uri, address)
      { use_ssl: uri.scheme == 'https', ipaddr: address, open_timeout: 5, read_timeout: 20 }
    end

    def build_request(uri, headers)
      request = Net::HTTP::Get.new(uri)
      request['User-Agent'] = USER_AGENT
      headers.each { |key, value| request[key] = value }
      request
    end

    def read_response(response)
      raise TooLarge if response['content-length'].to_i > MAX_BYTES

      HttpResponse.new(status: response.code.to_i, body: read_body(response), headers: header_map(response))
    end

    def read_body(response)
      body = +''.b
      response.read_body do |chunk|
        body << chunk
        raise TooLarge if body.bytesize > MAX_BYTES
      end
      body
    end

    def header_map(response)
      response.each_header.to_h
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

    class Error < StandardError; end
    class TooLarge < Error; end
  end
end
