# Decides whether a request really comes from a search engine crawler we want
# to let through the throttles.
#
# A User-Agent string proves nothing: any scraper can send "Googlebot". The
# search engines document the real check instead (reverse DNS of the client IP
# must land on the engine's own domain, and that hostname must resolve forward
# to the same IP). That takes a DNS round trip, which must never happen inside
# the Rack::Attack middleware, so:
#
#   * `verified?` only reads the cache. A hit answers immediately.
#   * A miss answers false (the request is throttled like any visitor) and
#     enqueues VerifyIpJob once, which fills the cache for next time.
#
# Two verification methods, matching what each crawler publishes:
#
#   * reverse DNS (Google, Bing, Baidu, Yandex, Apple): see `check_dns`.
#   * published IP ranges (OpenAI, Perplexity, Common Crawl, DuckDuckGo, and
#     Anthropic): the request IP must fall inside the ranges the operator
#     publishes. Ranges are fetched by RefreshRangesJob and cached, so
#     `verified?` never does network I/O.
#
# Crawlers that publish neither (Bytespider, Meta's crawlers) get no bypass and
# are throttled like any visitor; see the README.
module VerifiedBot
  ENGINES = {
    # Reverse DNS.
    "googlebot" => { ua: /Googlebot/i, domains: %w[googlebot.com google.com] },
    "bingbot" => { ua: /bingbot/i, domains: %w[search.msn.com] },
    "baidu" => { ua: /Baiduspider/i, domains: %w[baidu.com baidu.jp] },
    "yandex" => { ua: /YandexBot/i, domains: %w[yandex.ru yandex.net yandex.com] },
    "applebot" => { ua: /Applebot/i, domains: %w[applebot.apple.com] },
    # Published IP ranges (JSON: {"prefixes": [{"ipv4Prefix"|"ipv6Prefix": cidr}]}).
    "gptbot" => { ua: /GPTBot/i, ranges_url: "https://openai.com/gptbot.json" },
    "oai-searchbot" => { ua: /OAI-?SearchBot/i, ranges_url: "https://openai.com/searchbot.json" },
    "chatgpt-user" => { ua: /ChatGPT-User/i, ranges_url: "https://openai.com/chatgpt-user.json" },
    "perplexitybot" => { ua: /PerplexityBot/i, ranges_url: "https://www.perplexity.ai/perplexitybot.json" },
    "perplexity-user" => { ua: /Perplexity-User/i, ranges_url: "https://www.perplexity.ai/perplexity-user.json" },
    "ccbot" => { ua: /CCBot/i, ranges_url: "https://index.commoncrawl.org/ccbot.json" },
    "duckduckbot" => { ua: /DuckDuckBot/i, ranges_url: "https://duckduckgo.com/duckduckbot.json" },
    "anthropic" => {
      ua: /Claude-?SearchBot|ClaudeBot|Claude-User|anthropic-ai/i,
      ranges_url: "https://claude.com/crawling/bots.json"
    }
  }.freeze

  RANGES_TTL = 3.days # refreshed daily; survives two failed refreshes
  MAX_RANGES_BYTES = 2.megabytes
  MAX_PREFIXES = 10_000
  MIN_PREFIX_LENGTH = { 4 => 8, 6 => 16 }.freeze # reject absurdly broad CIDRs (e.g. 0.0.0.0/0)

  VERIFIED_TTL = 7.days
  REJECTED_TTL = 1.day
  PENDING_TTL = 10.minutes

  class LookupError < StandardError; end

  class << self
    # The cache is read on every request that claims to be a crawler, so keep
    # it a plain lookup.
    def cache
      config.cache
    end

    def config
      @config ||= Configuration.new
    end

    def configure
      yield config
    end

    # Built-in engines plus any added through `config.engines`.
    def engines
      ENGINES.merge(config.engines)
    end

    # The engine a User-Agent claims to be, or nil.
    def claimed_engine(user_agent)
      ua = user_agent.to_s
      return nil if ua.empty?

      engines.find { |_name, cfg| ua.match?(cfg[:ua]) }&.first
    end

    # True only when the UA claims an engine AND the IP has already been
    # verified as that engine. Never raises and never does DNS.
    def verified?(ip, user_agent)
      engine = claimed_engine(user_agent)
      return false if engine.nil? || ip.blank?

      return in_published_ranges?(ip, engine) unless engines[engine][:domains]

      status = cache.read(cache_key(ip, engine))
      if status.nil?
        enqueue_verification(ip, engine)
        return false
      end
      status == true
    rescue StandardError => e
      config.logger&.warn("[VerifiedBot] cache read failed: #{e.class}: #{e.message}")
      false
    end

    # Reverse + forward DNS check. Returns true/false for a definitive answer
    # and raises LookupError when DNS itself failed (so callers don't cache a
    # transient timeout as "this is a fake bot").
    def check_dns(ip, engine)
      domains = engines.fetch(engine)[:domains]
      host = reverse_lookup(ip)
      return false if host.nil?

      host = host.downcase.delete_suffix(".")
      return false unless domains.any? { |d| host == d || host.end_with?(".#{d}") }

      forward_lookup(host).include?(normalize(ip))
    end

    # Engines verified by published ranges (the refresh job's work list).
    def range_engines
      engines.select { |_name, cfg| cfg[:ranges_url] }.keys
    end

    # Fetch an engine's published ranges and cache them. Keeps the previous
    # list untouched on any failure. Raises LookupError so the job can retry.
    def refresh_ranges(engine)
      url = engines.fetch(engine).fetch(:ranges_url)
      prefixes = parse_prefixes(fetch_json(url))
      cache.write(ranges_key(engine), { "fetched_at" => Time.now.to_f, "prefixes" => prefixes }, expires_in: RANGES_TTL)
      prefixes.size
    end

    def ranges_key(engine)
      "verified_bot:ranges:#{engine}"
    end

    # Drops the per-process parsed-range memo (used by tests).
    def reset_range_memo!
      @range_memo = {}
    end

    def record(ip, engine, verified)
      cache.write(cache_key(ip, engine), verified, expires_in: verified ? VERIFIED_TTL : REJECTED_TTL)
    end

    def cache_key(ip, engine)
      "verified_bot:#{engine}:#{ip}"
    end

    # Lets a later request enqueue a fresh verification (used when DNS failed
    # and the job gave up without a verdict).
    def clear_pending(ip, engine)
      cache.delete(pending_key(ip, engine))
    end

    def clear_ranges_pending(engine)
      cache.delete(ranges_pending_key(engine))
    end

    def ranges_pending_key(engine)
      "verified_bot:ranges_pending:#{engine}"
    end

    def pending_key(ip, engine)
      "verified_bot:pending:#{engine}:#{ip}"
    end

    private

    def enqueue_verification(ip, engine)
      # `unless_exist` makes the first request win, so a burst of requests from
      # one unverified IP enqueues a single job rather than one each.
      return unless cache.write(pending_key(ip, engine), true, expires_in: PENDING_TTL, unless_exist: true)

      VerifyIpJob.perform_later(ip.to_s, engine)
    end

    def in_published_ranges?(ip, engine)
      ranges = ranges_for(engine)
      if ranges.nil?
        enqueue_range_refresh(engine)
        return false
      end

      addr = IPAddr.new(ip.to_s)
      addr = addr.native if addr.ipv4_mapped?
      ranges.any? { |range| range.include?(addr) }
    rescue IPAddr::InvalidAddressError
      false
    end

    # Parsed ranges for an engine, or nil when none are cached yet. Parsing
    # hundreds of CIDRs per request would be wasteful, so the parsed list is
    # memoised per process and keyed on the cache entry's fetch time.
    def ranges_for(engine)
      entry = cache.read(ranges_key(engine))
      return nil unless entry

      @range_memo ||= {}
      memo = @range_memo[engine]
      return memo[:list] if memo && memo[:stamp] == entry["fetched_at"]

      list = entry["prefixes"].map { |c| IPAddr.new(c) }
      @range_memo[engine] = { stamp: entry["fetched_at"], list: list }
      list
    end

    def enqueue_range_refresh(engine)
      return unless cache.write(ranges_pending_key(engine), true, expires_in: PENDING_TTL, unless_exist: true)

      RefreshRangesJob.perform_later(engine)
    end

    def fetch_json(url)
      uri = URI.parse(url)
      raise LookupError, "refusing non-https ranges url #{url}" unless uri.is_a?(URI::HTTPS)

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 10) do |http|
        http.request(Net::HTTP::Get.new(uri, "Accept" => "application/json", "User-Agent" => config.user_agent))
      end
      raise LookupError, "#{url} returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
      raise LookupError, "#{url} body too large" if response.body.to_s.bytesize > MAX_RANGES_BYTES

      JSON.parse(response.body)
    rescue JSON::ParserError => e
      raise LookupError, "#{url} returned invalid JSON: #{e.message[0, 80]}"
    rescue Timeout::Error, SystemCallError, IOError, SocketError, OpenSSL::SSL::SSLError => e
      raise LookupError, "fetching #{url} failed: #{e.class}"
    end

    # CIDR strings from {"prefixes": [{"ipv4Prefix"|"ipv6Prefix": ...}]}. Raises
    # on anything that looks wrong so a bad or tampered file never replaces a
    # good cached list.
    def parse_prefixes(json)
      raw = json.is_a?(Hash) ? json["prefixes"] : nil
      raise LookupError, "no prefixes array" unless raw.is_a?(Array) && raw.any?
      raise LookupError, "too many prefixes (#{raw.size})" if raw.size > MAX_PREFIXES

      raw.map do |entry|
        cidr = entry.is_a?(Hash) ? (entry["ipv4Prefix"] || entry["ipv6Prefix"]) : nil
        raise LookupError, "prefix entry without a CIDR" if cidr.blank?

        range = IPAddr.new(cidr)
        family = range.ipv4? ? 4 : 6
        raise LookupError, "suspiciously broad prefix #{cidr}" if range.prefix < MIN_PREFIX_LENGTH.fetch(family)

        cidr
      end
    rescue IPAddr::Error => e
      raise LookupError, "invalid prefix: #{e.message[0, 80]}"
    end

    def reverse_lookup(ip)
      resolver { |r| r.getname(ip.to_s).to_s }
    rescue Resolv::ResolvError => e
      raise LookupError, "reverse lookup timed out for #{ip}" if timeout?(e)

      nil # no PTR record: a definitive "not this engine"
    rescue Timeout::Error, SystemCallError, IOError => e
      raise LookupError, "reverse lookup failed for #{ip}: #{e.class}"
    end

    def forward_lookup(host)
      resolver { |r| r.getaddresses(host).map { |a| normalize(a) } }
    rescue Resolv::ResolvError => e
      raise LookupError, "forward lookup timed out for #{host}" if timeout?(e)

      []
    rescue Timeout::Error, SystemCallError, IOError => e
      raise LookupError, "forward lookup failed for #{host}: #{e.class}"
    end

    # raise_timeout_errors makes Resolv report a timeout as an error. Without
    # it a dead nameserver looks exactly like "no such record", and a real
    # crawler would be cached as fake.
    #
    # Passing any options makes Resolv skip the system resolver settings, so
    # they are loaded explicitly; a bare options hash would have no nameservers
    # and every lookup would time out.
    def resolver
      options = Resolv::DNS::Config.default_config_hash.merge(raise_timeout_errors: true)
      options[:nameserver_port] = config.nameservers if config.nameservers
      options.delete(:nameserver) if config.nameservers
      Resolv::DNS.open(options) { |dns| dns.timeouts = [ 2, 2 ]; yield dns }
    end

    def timeout?(error)
      error.message.match?(/timeout/i)
    end

    # Compare IPs in canonical form so "2001:db8::1" and "2001:0db8::1" match.
    def normalize(addr)
      IPAddr.new(addr.to_s).to_s
    rescue IPAddr::InvalidAddressError
      addr.to_s
    end
  end
end
