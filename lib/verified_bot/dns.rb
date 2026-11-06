require "socket"
require "securerandom"
require "resolv"

module VerifiedBot
  # A minimal DNS client for the two lookups crawler verification needs (PTR
  # and A/AAAA).
  #
  # Ruby's Resolv reports a timeout, SERVFAIL or REFUSED as "no such record",
  # which would make a real crawler look fake whenever the nameserver hiccups.
  # Here only a real NXDOMAIN or an empty answer means "no record"; everything
  # else raises LookupError so nothing is cached and the job retries.
  module DNS
    NO_ERROR = Resolv::DNS::RCode::NoError
    NX_DOMAIN = Resolv::DNS::RCode::NXDomain

    class << self
      # Hostname the IP's PTR record points at, or nil when there is none.
      def ptr(ip)
        name = reverse_name(ip)
        reply = query(name, Resolv::DNS::Resource::IN::PTR)
        record = reply&.answer&.map(&:last)&.find { |r| r.is_a?(Resolv::DNS::Resource::IN::PTR) }
        record&.name&.to_s
      end

      # Every A and AAAA address a hostname resolves to (empty when none).
      def addresses(host)
        [ Resolv::DNS::Resource::IN::A, Resolv::DNS::Resource::IN::AAAA ].flat_map do |type|
          reply = query(Resolv::DNS::Name.create(host.end_with?(".") ? host : "#{host}."), type)
          (reply&.answer || []).map(&:last).grep(type).map { |r| r.address.to_s }
        end
      end

      private

      def reverse_name(ip)
        addr = IPAddr.new(ip.to_s)
        addr = addr.native if addr.ipv4_mapped?
        (addr.ipv4? ? Resolv::IPv4 : Resolv::IPv6).create(addr.to_s).to_name
      rescue IPAddr::Error, ArgumentError
        raise LookupError, "not an IP address: #{ip.inspect}"
      end

      # The reply, or nil for NXDOMAIN. Raises LookupError for anything that
      # isn't a definitive answer from at least one nameserver.
      def query(name, type)
        failures = []
        nameservers.each do |host, port|
          VerifiedBot.config.dns_timeouts.each do |timeout|
            reply = ask(host, port, name, type, timeout)
            return nil if reply.rcode == NX_DOMAIN
            return reply if reply.rcode == NO_ERROR

            failures << "#{host} answered rcode #{reply.rcode}"
            break # a server that answers with an error won't improve on retry
          rescue Timeout::Error
            failures << "#{host} timed out"
          rescue SystemCallError, IOError, Resolv::DNS::DecodeError => e
            failures << "#{host}: #{e.class}"
            break
          end
        end
        raise LookupError, "DNS #{type.name.split("::").last} #{name} failed (#{failures.uniq.join(", ")})"
      end

      def nameservers
        configured = VerifiedBot.config.nameservers
        list = configured || Resolv::DNS::Config.default_config_hash[:nameserver].to_a.map { |h| [ h, 53 ] }
        raise LookupError, "no nameservers configured" if list.empty?

        list
      end

      def ask(host, port, name, type, timeout)
        message = Resolv::DNS::Message.new(SecureRandom.random_number(65_536))
        message.rd = 1
        message.add_question(name, type)
        reply = udp(host, port, message, timeout)
        reply = tcp(host, port, message, timeout) if reply.tc == 1
        reply
      end

      def udp(host, port, message, timeout)
        deadline = monotonic + timeout
        socket = UDPSocket.new(Addrinfo.ip(host).afamily)
        socket.send(message.encode, 0, host, port)
        loop do
          remaining = deadline - monotonic
          raise Timeout::Error if remaining <= 0 || !IO.select([ socket ], nil, nil, remaining)

          data, from = socket.recvfrom(4096)
          next unless same_host?(from[3], host) && from[1] == port # ignore stray packets

          reply = Resolv::DNS::Message.decode(data)
          return reply if reply.id == message.id # ignore spoofed or late replies
        rescue Resolv::DNS::DecodeError
          next
        end
      ensure
        socket&.close
      end

      def tcp(host, port, message, timeout)
        deadline = monotonic + timeout
        socket = Socket.tcp(host, port, connect_timeout: timeout)
        data = message.encode
        socket.write([ data.bytesize ].pack("n") + data)
        length = read_exactly(socket, 2, deadline).unpack1("n")
        reply = Resolv::DNS::Message.decode(read_exactly(socket, length, deadline))
        raise Resolv::DNS::DecodeError, "id mismatch" unless reply.id == message.id

        reply
      ensure
        socket&.close
      end

      def read_exactly(socket, count, deadline)
        buffer = +""
        while buffer.bytesize < count
          remaining = deadline - monotonic
          raise Timeout::Error if remaining <= 0 || !IO.select([ socket ], nil, nil, remaining)

          chunk = socket.read_nonblock(count - buffer.bytesize, exception: false)
          raise IOError, "connection closed" if chunk.nil?

          buffer << chunk unless chunk == :wait_readable
        end
        buffer
      end

      def same_host?(a, b)
        IPAddr.new(a) == IPAddr.new(b)
      rescue IPAddr::Error
        false
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
