require 'ipaddr'
require 'resolv'

module TrainingResources
  # Refuses link checks that would make the server fetch itself or an address on a
  # private network. Curators can add links, so a check has to treat the URL as untrusted.
  class OutboundUrlGuard
    class Forbidden < StandardError; end

    FORBIDDEN_HOSTS = %w[localhost localhost.localdomain metadata.google.internal].freeze

    def self.validate!(url, resolver: Resolv)
      new(resolver).validate!(url)
    end

    def initialize(resolver)
      @resolver = resolver
    end

    def validate!(url)
      uri = parse_http(url)
      raise Forbidden, 'private address' if forbidden_host?(uri.host) || forbidden_literal?(uri.host)
      return uri if ip_literal?(uri.host)

      addresses = Array(@resolver.getaddresses(uri.host))
      raise Forbidden, 'could not resolve' if addresses.empty?
      raise Forbidden, 'private address' if addresses.any? { |address| forbidden_ip?(address) }

      uri
    end

    private

    def parse_http(url)
      uri = URI.parse(url.to_s)
      allowed = uri.is_a?(URI::HTTP) && %w[http https].include?(uri.scheme)
      raise Forbidden, 'unsupported URL' unless allowed && uri.host.present? && uri.userinfo.blank?

      uri
    rescue URI::InvalidURIError
      raise Forbidden, 'unsupported URL'
    end

    def forbidden_host?(host)
      name = host.to_s.downcase.delete_suffix('.')
      FORBIDDEN_HOSTS.include?(name)
    end

    def forbidden_literal?(host)
      ip_literal?(host) && forbidden_ip?(host)
    end

    def ip_literal?(host)
      IPAddr.new(host)
      true
    rescue IPAddr::InvalidAddressError
      false
    end

    def forbidden_ip?(value)
      addr = IPAddr.new(value)
      addr.loopback? || addr.private? || addr.link_local? || unspecified?(addr) || multicast?(addr)
    rescue IPAddr::InvalidAddressError
      true
    end

    def unspecified?(addr)
      (addr.ipv4? && (addr.to_i >> 24).zero?) || (addr.ipv6? && addr == IPAddr.new('::'))
    end

    def multicast?(addr)
      return IPAddr.new('224.0.0.0/4').include?(addr) if addr.ipv4?
      return IPAddr.new('ff00::/8').include?(addr) if addr.ipv6?

      false
    end
  end
end
