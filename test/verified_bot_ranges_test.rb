require "test_helper"

# Verification by published IP ranges (OpenAI, Perplexity, Common Crawl,
# DuckDuckGo, Anthropic).
class VerifiedBotRangesTest < VerifiedBotTestCase
  include ActiveJob::TestHelper

  GPTBOT_UA = "Mozilla/5.0 (compatible; GPTBot/1.2; +https://openai.com/gptbot)".freeze

  setup do
    @original_cache = VerifiedBot.config.cache
    @store = ActiveSupport::Cache::MemoryStore.new
    store = @store
    VerifiedBot.config.cache = store
    VerifiedBot.reset_range_memo!
    @original_fetch = VerifiedBot.method(:fetch_json)
    @original_start = Net::HTTP.method(:start)
  end

  teardown do
    VerifiedBot.config.cache = @original_cache
    VerifiedBot.define_singleton_method(:fetch_json, @original_fetch)
    Net::HTTP.define_singleton_method(:start, @original_start)
    VerifiedBot.reset_range_memo!
  end

  def cache_ranges(engine, prefixes, fetched_at: 1.0)
    @store.write(VerifiedBot.ranges_key(engine), { "fetched_at" => fetched_at, "prefixes" => prefixes })
  end

  def stub_json(json)
    VerifiedBot.define_singleton_method(:fetch_json) { |_url| json }
  end

  def prefixes_json(*cidrs)
    { "prefixes" => cidrs.map { |c| c.include?(":") ? { "ipv6Prefix" => c } : { "ipv4Prefix" => c } } }
  end

  # --- verified? ---

  test "an IP inside the cached ranges is verified" do
    cache_ranges("gptbot", [ "132.196.86.0/24", "20.125.66.80/28" ])
    assert VerifiedBot.verified?("132.196.86.200", GPTBOT_UA)
    assert VerifiedBot.verified?("20.125.66.85", GPTBOT_UA)
  end

  test "an IP outside the cached ranges is not verified" do
    cache_ranges("gptbot", [ "132.196.86.0/24" ])
    assert_not VerifiedBot.verified?("132.196.87.1", GPTBOT_UA)
    assert_not VerifiedBot.verified?("203.0.113.9", GPTBOT_UA)
  end

  test "range boundaries are inclusive on the edges and exclusive just outside" do
    cache_ranges("gptbot", [ "132.196.86.0/24" ])
    assert VerifiedBot.verified?("132.196.86.0", GPTBOT_UA)
    assert VerifiedBot.verified?("132.196.86.255", GPTBOT_UA)
    assert_not VerifiedBot.verified?("132.196.85.255", GPTBOT_UA)
    assert_not VerifiedBot.verified?("132.196.87.0", GPTBOT_UA)
  end

  test "IPv6 ranges match IPv6 clients and IPv4-mapped addresses match IPv4 ranges" do
    cache_ranges("gptbot", [ "2600:1f28:365::/48", "132.196.86.0/24" ])
    assert VerifiedBot.verified?("2600:1f28:365:8000::1", GPTBOT_UA)
    assert_not VerifiedBot.verified?("2600:1f28:366::1", GPTBOT_UA)
    assert VerifiedBot.verified?("::ffff:132.196.86.9", GPTBOT_UA)
  end

  test "an IP verified for one engine is not verified for another" do
    cache_ranges("gptbot", [ "132.196.86.0/24" ])
    cache_ranges("ccbot", [ "3.41.188.0/24" ])
    assert_not VerifiedBot.verified?("132.196.86.7", "CCBot/2.0")
    assert_not VerifiedBot.verified?("3.41.188.7", GPTBOT_UA)
  end

  test "a malformed client IP is not verified and does not raise" do
    cache_ranges("gptbot", [ "132.196.86.0/24" ])
    assert_not VerifiedBot.verified?("not-an-ip", GPTBOT_UA)
    assert_not VerifiedBot.verified?("999.1.1.1", GPTBOT_UA)
  end

  test "with no ranges cached the request is not verified and one refresh is enqueued" do
    assert_enqueued_jobs 1, only: VerifiedBot::RefreshRangesJob do
      3.times { assert_not VerifiedBot.verified?("132.196.86.7", GPTBOT_UA) }
    end
    assert_enqueued_with(job: VerifiedBot::RefreshRangesJob, args: [ "gptbot" ])
  end

  test "a refreshed list replaces the memoised one" do
    cache_ranges("gptbot", [ "132.196.86.0/24" ], fetched_at: 1.0)
    assert VerifiedBot.verified?("132.196.86.7", GPTBOT_UA)

    cache_ranges("gptbot", [ "198.51.100.0/24" ], fetched_at: 2.0)
    assert_not VerifiedBot.verified?("132.196.86.7", GPTBOT_UA)
    assert VerifiedBot.verified?("198.51.100.7", GPTBOT_UA)
  end

  # --- Anthropic (claude.com/crawling/bots.json) ---

  ANTHROPIC_PREFIXES = [ "216.73.216.0/22", "34.162.230.222/32", "136.83.20.215/32" ].freeze

  test "Anthropic's published ranges verify ClaudeBot, Claude-SearchBot and anthropic-ai" do
    cache_ranges("anthropic", ANTHROPIC_PREFIXES)
    assert VerifiedBot.verified?("216.73.216.0", "ClaudeBot/1.0")
    assert VerifiedBot.verified?("216.73.219.255", "Claude-SearchBot/1.0")
    assert VerifiedBot.verified?("34.162.230.222", "anthropic-ai/1.0")
  end

  test "just outside Anthropic's published ranges is not verified" do
    cache_ranges("anthropic", ANTHROPIC_PREFIXES)
    assert_not VerifiedBot.verified?("216.73.215.255", "ClaudeBot/1.0")
    assert_not VerifiedBot.verified?("216.73.220.0", "ClaudeBot/1.0")
    assert_not VerifiedBot.verified?("34.162.230.223", "ClaudeBot/1.0") # a /32 is exactly one address
  end

  test "Anthropic's API outbound ranges are not crawler addresses" do
    cache_ranges("anthropic", ANTHROPIC_PREFIXES)
    assert_not VerifiedBot.verified?("160.79.104.5", "ClaudeBot/1.0")
    assert_not VerifiedBot.verified?("153.61.208.9", "ClaudeBot/1.0")
  end

  test "with Anthropic's ranges not cached ClaudeBot is not verified and one refresh is enqueued" do
    assert_enqueued_jobs 1, only: VerifiedBot::RefreshRangesJob do
      2.times { assert_not VerifiedBot.verified?("216.73.216.5", "ClaudeBot/1.0") }
    end
    assert_enqueued_with(job: VerifiedBot::RefreshRangesJob, args: [ "anthropic" ])
  end

  # --- refresh_ranges ---

  test "refresh_ranges caches the published prefixes and returns the count" do
    stub_json(prefixes_json("132.196.86.0/24", "2600:1f28:365::/48"))
    assert_equal 2, VerifiedBot.refresh_ranges("gptbot")
    assert VerifiedBot.verified?("2600:1f28:365::5", GPTBOT_UA)
  end

  test "range_engines lists only the engines verified by ranges" do
    assert_includes VerifiedBot.range_engines, "gptbot"
    assert_includes VerifiedBot.range_engines, "duckduckbot"
    assert_includes VerifiedBot.range_engines, "anthropic"
    assert_not_includes VerifiedBot.range_engines, "googlebot"
  end

  test "a bad file never replaces the last good list" do
    cache_ranges("gptbot", [ "132.196.86.0/24" ])
    [
      { "prefixes" => [] },
      { "nope" => 1 },
      [],
      { "prefixes" => [ { "ipv4Prefix" => "not-a-cidr" } ] },
      { "prefixes" => [ { "other" => "1.2.3.0/24" } ] },
      { "prefixes" => [ "1.2.3.0/24" ] },
      prefixes_json("0.0.0.0/0"),
      prefixes_json("::/0"),
      prefixes_json("1.0.0.0/7"),
      prefixes_json("132.196.86.0/24", "0.0.0.0/0")
    ].each do |bad|
      stub_json(bad)
      assert_raises(VerifiedBot::LookupError, bad.inspect) { VerifiedBot.refresh_ranges("gptbot") }
    end
    assert VerifiedBot.verified?("132.196.86.7", GPTBOT_UA)
  end

  test "an absurdly long list is rejected" do
    stub_json("prefixes" => Array.new(VerifiedBot::MAX_PREFIXES + 1) { { "ipv4Prefix" => "10.0.0.1/32" } })
    assert_raises(VerifiedBot::LookupError) { VerifiedBot.refresh_ranges("gptbot") }
  end

  # --- fetch_json (HTTP layer) ---

  def stub_http(code: "200", body: "{}", raises: nil)
    http = Object.new
    http.define_singleton_method(:request) do |_req|
      raise raises if raises

      res = Net::HTTPResponse::CODE_TO_OBJ.fetch(code).new("1.1", code, "x")
      res.instance_variable_set(:@body, body)
      res.instance_variable_set(:@read, true)
      res
    end
    Net::HTTP.define_singleton_method(:start) { |*_a, **_k, &blk| blk.call(http) }
  end

  test "fetch_json parses a 200 JSON body" do
    stub_http(body: '{"prefixes":[{"ipv4Prefix":"1.2.3.0/24"}]}')
    assert_equal({ "prefixes" => [ { "ipv4Prefix" => "1.2.3.0/24" } ] }, VerifiedBot.send(:fetch_json, "https://example.com/x.json"))
  end

  test "fetch_json treats redirects and server errors as failures" do
    %w[302 404 500 503].each do |code|
      stub_http(code: code)
      assert_raises(VerifiedBot::LookupError, code) { VerifiedBot.send(:fetch_json, "https://example.com/x.json") }
    end
  end

  test "fetch_json raises LookupError on invalid JSON, timeouts and connection errors" do
    stub_http(body: "<html>nope</html>")
    assert_raises(VerifiedBot::LookupError) { VerifiedBot.send(:fetch_json, "https://example.com/x.json") }

    [ Timeout::Error, Errno::ECONNREFUSED, SocketError, OpenSSL::SSL::SSLError ].each do |error|
      stub_http(raises: error)
      assert_raises(VerifiedBot::LookupError, error.name) { VerifiedBot.send(:fetch_json, "https://example.com/x.json") }
    end
  end

  test "fetch_json refuses non-https URLs and oversized bodies" do
    assert_raises(VerifiedBot::LookupError) { VerifiedBot.send(:fetch_json, "http://example.com/x.json") }
    stub_http(body: "x" * (VerifiedBot::MAX_RANGES_BYTES + 1))
    assert_raises(VerifiedBot::LookupError) { VerifiedBot.send(:fetch_json, "https://example.com/x.json") }
  end

  test "every configured ranges url is https" do
    VerifiedBot::ENGINES.each_value do |cfg|
      assert cfg[:ranges_url].start_with?("https://"), cfg[:ranges_url] if cfg[:ranges_url]
    end
  end
end
