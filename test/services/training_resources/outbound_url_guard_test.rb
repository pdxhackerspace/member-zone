require 'test_helper'

module TrainingResources
  class OutboundUrlGuardTest < ActiveSupport::TestCase
    test 'allows a public address' do
      uri = OutboundUrlGuard.validate!(
        'https://example.com/guide', resolver: resolver('93.184.216.34')
      )

      assert_equal 'example.com', uri.host
    end

    test 'refuses loopback, private, and link-local addresses' do
      ['127.0.0.1', '10.1.2.3', '192.168.1.9', '169.254.169.254', '::1'].each do |address|
        error = assert_raises(OutboundUrlGuard::Forbidden) do
          OutboundUrlGuard.validate!("https://example.com/#{address}", resolver: resolver(address))
        end
        assert_equal 'private address', error.message
      end
    end

    test 'refuses an address written into the URL itself' do
      error = assert_raises(OutboundUrlGuard::Forbidden) do
        OutboundUrlGuard.validate!('http://127.0.0.1/latest')
      end

      assert_equal 'private address', error.message
    end

    test 'refuses an IPv4 address written as an IPv6 mapped address' do
      error = assert_raises(OutboundUrlGuard::Forbidden) do
        OutboundUrlGuard.validate!('https://example.com/guide', resolver: resolver('::ffff:127.0.0.1'))
      end
      assert_equal 'private address', error.message

      literal = assert_raises(OutboundUrlGuard::Forbidden) do
        OutboundUrlGuard.validate!('http://[::ffff:169.254.169.254]/latest')
      end
      assert_equal 'private address', literal.message
    end

    test 'refuses localhost and a URL with credentials' do
      assert_raises(OutboundUrlGuard::Forbidden) do
        OutboundUrlGuard.validate!('http://localhost/guide', resolver: resolver('93.184.216.34'))
      end
      assert_raises(OutboundUrlGuard::Forbidden) do
        OutboundUrlGuard.validate!('https://user:pass@example.com/guide')
      end
    end

    private

    def resolver(address)
      Struct.new(:address) do
        def getaddresses(_host)
          [address]
        end
      end.new(address)
    end
  end
end
