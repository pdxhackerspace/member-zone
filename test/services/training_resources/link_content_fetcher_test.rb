require 'test_helper'
require 'net/http'

module TrainingResources
  class LinkContentFetcherTest < ActiveSupport::TestCase
    test 'the download connects to the address the guard accepted' do
      seen = {}
      response = Net::HTTPNotModified.new('1.1', '304', 'Not Modified')
      response['content-length'] = '0'
      response.define_singleton_method(:read_body) { |&block| block&.call('') }

      with_http_start(lambda { |host, **options, &block|
        seen[:host] = host
        seen[:ipaddr] = options[:ipaddr]
        block.call(http_yielding(response))
      }) do
        result = LinkContentFetcher.call('https://example.com/laser-safety', resolver: public_resolver)

        assert_equal :not_modified, result.status
      end

      assert_equal 'example.com', seen[:host]
      assert_equal '93.184.216.34', seen[:ipaddr]
    end

    test 'a declared content length over the cap is not read' do
      response = Net::HTTPOK.new('1.1', '200', 'OK')
      response['content-length'] = (LinkContentFetcher::MAX_BYTES + 1).to_s
      read = false
      response.define_singleton_method(:read_body) { read = true }

      with_http_start(->(_host, **_options, &block) { block.call(http_yielding(response)) }) do
        result = LinkContentFetcher.call('https://example.com/huge', resolver: public_resolver)

        assert_equal :too_large, result.status
      end
      assert_not read
    end

    private

    def with_http_start(implementation)
      original = Net::HTTP.method(:start)
      Net::HTTP.define_singleton_method(:start) do |host, _port = nil, **options, &block|
        implementation.call(host, **options, &block)
      end
      yield
    ensure
      Net::HTTP.define_singleton_method(:start) { |*args, **kwargs, &block| original.call(*args, **kwargs, &block) }
    end

    def http_yielding(response)
      http = Object.new
      http.define_singleton_method(:request) { |_request, &block| block.call(response) }
      http
    end

    def public_resolver
      Struct.new(:address) do
        def getaddresses(_host)
          ['93.184.216.34']
        end
      end.new('93.184.216.34')
    end
  end
end
