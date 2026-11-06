require "test_helper"
require "socket"
require "openssl"
require "tempfile"

# Runs the REAL Resolv::DNS and Net::HTTP code against servers on localhost, so
# the resolver, TLS, redirect and size-limit handling are exercised offline.
class RealNetworkStackTest < VerifiedBotTestCase
  # --- a minimal UDP DNS server: PTR and A answers from a table ---------------

  class TinyDNS
    A = Resolv::DNS::Resource::IN::A
    AAAA = Resolv::DNS::Resource::IN::AAAA
    PTR = Resolv::DNS::Resource::IN::PTR

    attr_reader :port, :queries

    # ptr/a/aaaa: name => data. Behaviours: silent (never answers), drop (query
    # types ignored), rcode (error for everything), truncate (UDP answers set
    # TC; the full answer comes over TCP), wrong_id_first (sends a spoofed
    # reply before the real one), garbage (undecodable bytes).
    def initialize(ptr: {}, a: {}, aaaa: {}, silent: false, drop: [], rcode: nil, truncate: false,
                   wrong_id_first: false, garbage: false, decoy: false)
      @ptr, @a, @aaaa, @silent, @drop, @rcode = ptr, a, aaaa, silent, drop, rcode
      @truncate, @wrong_id_first, @garbage, @decoy = truncate, wrong_id_first, garbage, decoy
      @decoy_socket = UDPSocket.new if decoy
      @queries = []
      @udp = UDPSocket.new
      @udp.bind("127.0.0.1", 0)
      @port = @udp.addr[1]
      @threads = [ Thread.new { serve_udp } ]
      return unless truncate

      @tcp = TCPServer.new("127.0.0.1", @port)
      @threads << Thread.new { serve_tcp }
    end

    def stop
      @threads.each(&:kill)
      @udp.close
      @decoy_socket&.close
      @tcp&.close
    end

    private

    def serve_udp
      loop do
        data, (_, port, _, host) = @udp.recvfrom(512)
        next if @silent

        query = Resolv::DNS::Message.decode(data)
        @queries << query.question.first.then { |name, type| [ name.to_s, type ] }
        next if @drop.include?(query.question.first[1])

        if @garbage
          @udp.send("\x00\x01garbage", 0, host, port)
          next
        end
        @udp.send(spoofed(query).encode, 0, host, port) if @wrong_id_first && query.question.first[1] == PTR
        send_decoy(query, host, port) if @decoy && query.question.first[1] == PTR
        @udp.send(reply_to(query, tc: @truncate).encode, 0, host, port)
      end
    end

    # Right ID, but from a different source port than the one that was queried.
    def send_decoy(query, host, port)
      @decoy_socket.send(spoofed(query, id: query.id).encode, 0, host, port)
    end

    def serve_tcp
      loop do
        client = @tcp.accept
        length = client.read(2).unpack1("n")
        query = Resolv::DNS::Message.decode(client.read(length))
        data = reply_to(query, tc: false).encode
        client.write([ data.bytesize ].pack("n") + data)
        client.close
      rescue IOError, SystemCallError
        next
      end
    end

    def spoofed(query, id: (query.id + 1) % 65_536)
      reply = Resolv::DNS::Message.new(id)
      reply.qr = 1
      reply.add_question(*query.question.first)
      reply.add_answer(query.question.first[0], 60, Resolv::DNS::Resource::IN::PTR.new(Resolv::DNS::Name.create("crawl.googlebot.com.")))
      reply
    end

    def reply_to(query, tc:)
      reply = Resolv::DNS::Message.new(query.id)
      reply.qr = 1
      reply.rd = 1
      reply.ra = 1
      reply.tc = tc ? 1 : 0
      name, type = query.question.first
      reply.add_question(name, type)
      return reply.tap { |r| r.rcode = @rcode } if @rcode
      return reply if tc # truncated: no answers, the client retries over TCP

      fill(reply, name, type)
      reply
    end

    def fill(reply, name, type)
      key = name.to_s
      if type == PTR && (host = @ptr[key])
        reply.add_answer(name, 60, PTR.new(Resolv::DNS::Name.create("#{host}.")))
      elsif type == A && (ips = @a[key])
        ips.each { |ip| reply.add_answer(name, 60, A.new(ip)) }
      elsif type == AAAA && (ips = @aaaa[key])
        ips.each { |ip| reply.add_answer(name, 60, AAAA.new(ip)) }
      elsif !(@ptr.key?(key) || @a.key?(key) || @aaaa.key?(key))
        reply.rcode = Resolv::DNS::RCode::NXDomain
      end # else NODATA: the name exists, with no records of this type
    end
  end

  def with_dns_server(**opts)
    server = TinyDNS.new(**opts)
    VerifiedBot.config.nameservers = [ [ "127.0.0.1", server.port ] ]
    VerifiedBot.config.dns_timeouts = [ 0.3, 0.3 ]
    yield server
  ensure
    server&.stop
  end

  GOOGLE_PTR = { "1.66.249.66.in-addr.arpa" => "crawl-66-249-66-1.googlebot.com" }.freeze
  GOOGLE_A = { "crawl-66-249-66-1.googlebot.com" => [ "66.249.66.1" ] }.freeze

  test "real resolver: a genuine Googlebot passes reverse and forward lookup" do
    with_dns_server(ptr: GOOGLE_PTR, a: GOOGLE_A) do |server|
      assert VerifiedBot.check_dns("66.249.66.1", "googlebot")
      assert_includes server.queries.map(&:first), "1.66.249.66.in-addr.arpa"
    end
  end

  test "the system resolvers are used when no nameservers are configured" do
    stub_singleton(Resolv::DNS::Config, :default_config_hash) { { nameserver: [ "192.0.2.53" ] } }
    assert_equal [ [ "192.0.2.53", 53 ] ], VerifiedBot::DNS.send(:nameservers)
  end

  test "configured nameservers replace the system ones" do
    VerifiedBot.config.nameservers = [ [ "127.0.0.1", 5353 ] ]
    assert_equal [ [ "127.0.0.1", 5353 ] ], VerifiedBot::DNS.send(:nameservers)
  end

  test "no nameservers at all is a lookup failure, not a verdict" do
    stub_singleton(Resolv::DNS::Config, :default_config_hash) { { nameserver: [] } }
    assert_raises(VerifiedBot::LookupError) { VerifiedBot.check_dns("66.249.66.1", "googlebot") }
  end

  test "real resolver: no PTR record is a definitive no" do
    with_dns_server do
      assert_equal false, VerifiedBot.check_dns("203.0.113.9", "googlebot")
    end
  end

  test "real resolver: a PTR on the engine's domain that resolves elsewhere is rejected" do
    with_dns_server(ptr: GOOGLE_PTR, a: { "crawl-66-249-66-1.googlebot.com" => [ "198.51.100.1" ] }) do
      assert_equal false, VerifiedBot.check_dns("66.249.66.1", "googlebot")
    end
  end

  test "real resolver: a PTR on a look-alike domain is rejected without a forward lookup" do
    ptr = { "9.113.0.203.in-addr.arpa" => "crawl.googlebot.com.evil.example" }
    with_dns_server(ptr: ptr) do |server|
      assert_equal false, VerifiedBot.check_dns("203.0.113.9", "googlebot")
      assert_equal 1, server.queries.size
    end
  end

  test "real resolver: an unresponsive server raises LookupError, never a verdict" do
    with_dns_server(silent: true) do
      assert_raises(VerifiedBot::LookupError) { VerifiedBot.check_dns("66.249.66.1", "googlebot") }
    end
  end

  test "real resolver: a dead forward lookup after a good PTR raises LookupError" do
    with_dns_server(ptr: GOOGLE_PTR, drop: [ Resolv::DNS::Resource::IN::A ]) do
      assert_raises(VerifiedBot::LookupError) { VerifiedBot.check_dns("66.249.66.1", "googlebot") }
    end
  end

  test "real resolver: a timeout caches nothing, so the crawler is retried rather than blocked" do
    with_dns_server(silent: true) do
      VerifiedBot::VerifyIpJob.perform_now("66.249.66.1", "googlebot")
      assert_nil @store.read(VerifiedBot.cache_key("66.249.66.1", "googlebot"))
    end
  end

  test "real resolver: SERVFAIL and REFUSED are failures, not 'no record'" do
    [ Resolv::DNS::RCode::ServFail, Resolv::DNS::RCode::Refused ].each do |rcode|
      with_dns_server(rcode: rcode) do
        error = assert_raises(VerifiedBot::LookupError) { VerifiedBot.check_dns("66.249.66.1", "googlebot") }
        assert_match(/rcode #{rcode}/, error.message)
      end
    end
  end

  test "real resolver: a SERVFAIL caches no verdict" do
    with_dns_server(rcode: Resolv::DNS::RCode::ServFail) do
      VerifiedBot::VerifyIpJob.perform_now("66.249.66.1", "googlebot")
      assert_nil @store.read(VerifiedBot.cache_key("66.249.66.1", "googlebot"))
    end
  end

  test "real resolver: a truncated UDP answer is retried over TCP" do
    with_dns_server(ptr: GOOGLE_PTR, a: GOOGLE_A, truncate: true) do
      assert VerifiedBot.check_dns("66.249.66.1", "googlebot")
    end
  end

  test "real resolver: a reply with the wrong ID is ignored, not trusted" do
    # The spoofed reply claims crawl.googlebot.com, which would pass the forward
    # check; the real PTR says scraper.example.net.
    ptr = { "9.113.0.203.in-addr.arpa" => "scraper.example.net" }
    with_dns_server(ptr: ptr, a: { "crawl.googlebot.com" => [ "203.0.113.9" ] }, wrong_id_first: true) do
      assert_equal false, VerifiedBot.check_dns("203.0.113.9", "googlebot")
    end
  end

  test "real resolver: a correctly-numbered reply from the wrong source is ignored" do
    ptr = { "9.113.0.203.in-addr.arpa" => "scraper.example.net" }
    with_dns_server(ptr: ptr, a: { "crawl.googlebot.com" => [ "203.0.113.9" ] }, decoy: true) do
      assert_equal false, VerifiedBot.check_dns("203.0.113.9", "googlebot")
    end
  end

  test "real resolver: an undecodable reply is a failure" do
    with_dns_server(garbage: true) do
      assert_raises(VerifiedBot::LookupError) { VerifiedBot.check_dns("66.249.66.1", "googlebot") }
    end
  end

  test "real resolver: the next nameserver is tried when the first fails" do
    good = TinyDNS.new(ptr: GOOGLE_PTR, a: GOOGLE_A)
    bad = TinyDNS.new(rcode: Resolv::DNS::RCode::ServFail)
    VerifiedBot.config.nameservers = [ [ "127.0.0.1", bad.port ], [ "127.0.0.1", good.port ] ]
    VerifiedBot.config.dns_timeouts = [ 0.3 ]
    assert VerifiedBot.check_dns("66.249.66.1", "googlebot")
  ensure
    good&.stop
    bad&.stop
  end

  test "real resolver: a silent first nameserver falls through to the second" do
    silent = TinyDNS.new(silent: true)
    good = TinyDNS.new(ptr: GOOGLE_PTR, a: GOOGLE_A)
    VerifiedBot.config.nameservers = [ [ "127.0.0.1", silent.port ], [ "127.0.0.1", good.port ] ]
    VerifiedBot.config.dns_timeouts = [ 0.2 ]
    assert VerifiedBot.check_dns("66.249.66.1", "googlebot")
  ensure
    silent&.stop
    good&.stop
  end

  test "real resolver: IPv6 clients use ip6.arpa PTR names and AAAA records" do
    ip = "2001:4860:4801:10::1"
    ptr_name = Resolv::IPv6.create(ip).to_name.to_s
    with_dns_server(ptr: { ptr_name => "crawl-v6.googlebot.com" }, aaaa: { "crawl-v6.googlebot.com" => [ ip ] }) do |server|
      assert VerifiedBot.check_dns(ip, "googlebot")
      assert_includes server.queries.map(&:first), ptr_name
    end
  end

  test "real resolver: IPv4-mapped IPv6 clients are looked up as IPv4" do
    with_dns_server(ptr: GOOGLE_PTR, a: GOOGLE_A) do
      assert VerifiedBot.check_dns("::ffff:66.249.66.1", "googlebot")
    end
  end

  test "real resolver: a host with only an A record and no AAAA is not an error (NODATA)" do
    with_dns_server(ptr: GOOGLE_PTR, a: GOOGLE_A) do |server|
      assert VerifiedBot.check_dns("66.249.66.1", "googlebot")
      assert(server.queries.any? { |_n, type| type == TinyDNS::AAAA })
    end
  end

  test "real resolver: a malformed client IP is a lookup error, not a crash" do
    assert_raises(VerifiedBot::LookupError) { VerifiedBot::DNS.ptr("not-an-ip") }
  end

  test "real resolver: the whole flow through the job" do
    with_dns_server(ptr: GOOGLE_PTR, a: GOOGLE_A) do
      ua = "Mozilla/5.0 (compatible; Googlebot/2.1)"
      assert_not VerifiedBot.verified?("66.249.66.1", ua)
      perform_enqueued_jobs
      assert VerifiedBot.verified?("66.249.66.1", ua)
    end
  end

  # --- a minimal HTTPS server with a throwaway certificate --------------------

  def self.certificate
    @certificate ||= begin
      key = OpenSSL::PKey::RSA.new(2048)
      cert = OpenSSL::X509::Certificate.new
      cert.version = 2
      cert.serial = 1
      cert.subject = cert.issuer = OpenSSL::X509::Name.parse("/CN=localhost")
      cert.public_key = key.public_key
      cert.not_before = Time.now - 60
      cert.not_after = Time.now + 3600
      ef = OpenSSL::X509::ExtensionFactory.new(cert, cert)
      cert.add_extension(ef.create_extension("subjectAltName", "DNS:localhost,IP:127.0.0.1"))
      cert.add_extension(ef.create_extension("basicConstraints", "CA:TRUE", true))
      cert.sign(key, OpenSSL::Digest.new("SHA256"))
      [ cert, key ]
    end
  end

  # routes: { "/path" => [status, headers, body] }
  def with_https_server(routes, trusted: true)
    cert, key = self.class.certificate
    ctx = OpenSSL::SSL::SSLContext.new
    ctx.cert = cert
    ctx.key = key
    tcp = TCPServer.new("127.0.0.1", 0)
    server = OpenSSL::SSL::SSLServer.new(tcp, ctx)
    thread = Thread.new do
      loop do
        client = server.accept
        request_line = client.gets.to_s
        while (line = client.gets) && line != "\r\n"; end
        status, headers, body = routes.fetch(request_line.split[1]) { [ 404, {}, "" ] }
        head = headers.merge("Content-Length" => body.bytesize.to_s, "Connection" => "close")
        client.write("HTTP/1.1 #{status} X\r\n#{head.map { |k, v| "#{k}: #{v}" }.join("\r\n")}\r\n\r\n#{body}")
        client.close
      rescue OpenSSL::SSL::SSLError, IOError, SystemCallError
        next
      end
    end

    with_trusted_cert(trusted) { yield "https://localhost:#{tcp.addr[1]}" }
  ensure
    thread&.kill
    tcp&.close
  end

  # The real Net::HTTP and OpenSSL verification run; we only tell them which CA
  # to trust (our throwaway certificate), for this test only.
  def with_trusted_cert(trusted)
    return yield unless trusted

    file = Tempfile.new([ "ca", ".pem" ])
    file.write(self.class.certificate.first.to_pem)
    file.close
    original = Net::HTTP.method(:start)
    stub_singleton(Net::HTTP, :start) { |host, port, **opts, &blk| original.call(host, port, **opts, ca_file: file.path, &blk) }
    yield
  ensure
    file&.unlink
  end

  GOOD_JSON = '{"prefixes":[{"ipv4Prefix":"20.171.206.0/24"},{"ipv6Prefix":"2600:1f28:365:80::/60"}]}'.freeze

  test "real HTTPS: refresh_ranges downloads, validates and caches a feed" do
    with_https_server({ "/ips.json" => [ 200, { "Content-Type" => "application/json" }, GOOD_JSON ] }) do |base|
      stub_singleton(VerifiedBot, :engines) { { "gptbot" => { ua: /GPTBot/i, ranges_url: "#{base}/ips.json" } } }
      assert_equal 2, VerifiedBot.refresh_ranges("gptbot")
      assert VerifiedBot.verified?("20.171.206.9", "GPTBot/1.2")
    end
  end

  test "real HTTPS: a redirect is treated as a failure, not followed" do
    with_https_server({ "/ips.json" => [ 302, { "Location" => "https://evil.example/ips.json" }, "" ] }) do |base|
      assert_raises(VerifiedBot::LookupError) { VerifiedBot.send(:fetch_json, "#{base}/ips.json") }
    end
  end

  test "real HTTPS: server errors and missing files raise LookupError" do
    with_https_server({ "/boom.json" => [ 503, {}, "down" ] }) do |base|
      assert_raises(VerifiedBot::LookupError) { VerifiedBot.send(:fetch_json, "#{base}/boom.json") }
      assert_raises(VerifiedBot::LookupError) { VerifiedBot.send(:fetch_json, "#{base}/missing.json") }
    end
  end

  test "real HTTPS: an oversized body is refused" do
    big = %({"prefixes":[],"pad":"#{"x" * (VerifiedBot::MAX_RANGES_BYTES + 10)}"})
    with_https_server({ "/big.json" => [ 200, {}, big ] }) do |base|
      error = assert_raises(VerifiedBot::LookupError) { VerifiedBot.send(:fetch_json, "#{base}/big.json") }
      assert_match(/too large/, error.message)
    end
  end

  test "real HTTPS: a non-JSON body raises LookupError" do
    with_https_server({ "/x.json" => [ 200, {}, "<html>" ] }) do |base|
      assert_raises(VerifiedBot::LookupError) { VerifiedBot.send(:fetch_json, "#{base}/x.json") }
    end
  end

  test "real HTTPS: a certificate we don't trust is refused" do
    with_https_server({ "/ips.json" => [ 200, {}, GOOD_JSON ] }, trusted: false) do |base|
      assert_raises(VerifiedBot::LookupError) { VerifiedBot.send(:fetch_json, "#{base}/ips.json") }
    end
  end

  test "real HTTP: a plain-http URL is refused before any connection" do
    assert_raises(VerifiedBot::LookupError) { VerifiedBot.send(:fetch_json, "http://127.0.0.1:1/ips.json") }
  end

  test "real HTTPS: a refused connection raises LookupError" do
    port = TCPServer.open("127.0.0.1", 0) { |s| s.addr[1] } # closed again straight away
    assert_raises(VerifiedBot::LookupError) { VerifiedBot.send(:fetch_json, "https://localhost:#{port}/ips.json") }
  end

  test "real HTTPS: a failed refresh keeps the last good ranges" do
    with_https_server({ "/ips.json" => [ 200, {}, GOOD_JSON ], "/bad.json" => [ 200, {}, '{"prefixes":[{"ipv4Prefix":"0.0.0.0/0"}]}' ] }) do |base|
      urls = { "gptbot" => { ua: /GPTBot/i, ranges_url: "#{base}/ips.json" } }
      stub_singleton(VerifiedBot, :engines) { urls }
      VerifiedBot.refresh_ranges("gptbot")
      urls["gptbot"][:ranges_url] = "#{base}/bad.json"
      assert_raises(VerifiedBot::LookupError) { VerifiedBot.refresh_ranges("gptbot") }
      assert VerifiedBot.verified?("20.171.206.9", "GPTBot/1.2")
    end
  end
end
