require "test_helper"

class VerifiedBotTest < VerifiedBotTestCase
  GOOGLEBOT_UA = "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)".freeze
  GOOD_IP = "66.249.66.1".freeze

  # Scripted resolver: ptr maps ip => hostname, forward maps hostname => [ips].
  class FakeDNS
    attr_writer :timeouts

    def initialize(ptr: {}, forward: {}, raise_on: nil)
      @ptr, @forward, @raise_on = ptr, forward, raise_on
    end

    def getname(ip)
      raise @raise_on if @raise_on == Timeout::Error
      @ptr.fetch(ip.to_s) { raise Resolv::ResolvError, "no PTR" }
    end

    def getaddresses(host)
      raise @raise_on if @raise_on == Timeout::Error
      @forward.fetch(host, [])
    end
  end


  def with_dns(fake)
    stub_singleton(Resolv::DNS, :open) { |&blk| blk.call(fake) }
  end

  def genuine_google
    FakeDNS.new(
      ptr: { GOOD_IP => "crawl-66-249-66-1.googlebot.com" },
      forward: { "crawl-66-249-66-1.googlebot.com" => [ GOOD_IP ] }
    )
  end

  # --- claimed_engine ---

  test "claimed_engine recognises each engine with a reverse DNS check" do
    {
      "Googlebot/2.1" => "googlebot",
      "Mozilla/5.0 (compatible; bingbot/2.0)" => "bingbot",
      "Mozilla/5.0 (compatible; Baiduspider/2.0)" => "baidu",
      "Mozilla/5.0 (compatible; YandexBot/3.0)" => "yandex",
      "Mozilla/5.0 (Macintosh) Applebot/0.1" => "applebot"
    }.each { |ua, engine| assert_equal engine, VerifiedBot.claimed_engine(ua), ua }
  end

  test "claimed_engine is nil for browsers, nil and blank UAs" do
    assert_nil VerifiedBot.claimed_engine("Mozilla/5.0 (Macintosh) Chrome/130 Safari/537.36")
    assert_nil VerifiedBot.claimed_engine(nil)
    assert_nil VerifiedBot.claimed_engine("")
  end

  test "claimed_engine recognises crawlers verified by published ranges" do
    {
      "Mozilla/5.0 (compatible; GPTBot/1.2; +https://openai.com/gptbot)" => "gptbot",
      "Mozilla/5.0 (compatible; OAI-SearchBot/1.0)" => "oai-searchbot",
      "Mozilla/5.0 (Macintosh) ChatGPT-User/1.0" => "chatgpt-user",
      "Mozilla/5.0 (compatible; PerplexityBot/1.0)" => "perplexitybot",
      "Mozilla/5.0 (compatible; Perplexity-User/1.0)" => "perplexity-user",
      "CCBot/2.0 (https://commoncrawl.org/faq/)" => "ccbot",
      "Mozilla/5.0 (compatible; DuckDuckBot/1.1)" => "duckduckbot",
      "Mozilla/5.0 (compatible; ClaudeBot/1.0; +claudebot@anthropic.com)" => "anthropic",
      "Mozilla/5.0 (compatible; Claude-SearchBot/1.0)" => "anthropic",
      "anthropic-ai/1.0" => "anthropic"
    }.each { |ua, engine| assert_equal engine, VerifiedBot.claimed_engine(ua), ua }
  end

  test "claimed_engine matches case-insensitively" do
    assert_equal "googlebot", VerifiedBot.claimed_engine("googlebot/2.1")
    assert_equal "gptbot", VerifiedBot.claimed_engine("GPTBOT/1.0")
  end

  test "claimed_engine is nil for crawlers that publish neither reverse DNS nor ranges" do
    %w[Bytespider Meta-ExternalAgent/1.1 meta-webindexer/1.1].each do |ua|
      assert_nil VerifiedBot.claimed_engine(ua), ua
    end
  end

  # --- verified? (cache only, no DNS) ---

  test "verified? is true for a claimed engine whose IP is cached as verified" do
    VerifiedBot.record(GOOD_IP, "googlebot", true)
    assert VerifiedBot.verified?(GOOD_IP, GOOGLEBOT_UA)
  end

  test "verified? is false when the IP is cached as rejected" do
    VerifiedBot.record("203.0.113.9", "googlebot", false)
    assert_not VerifiedBot.verified?("203.0.113.9", GOOGLEBOT_UA)
  end

  test "verified? is false for a browser UA and never enqueues a lookup" do
    assert_no_enqueued_jobs do
      assert_not VerifiedBot.verified?(GOOD_IP, "Mozilla/5.0 Chrome/130")
    end
  end

  test "verified? is false for a nil UA or blank IP without enqueueing" do
    assert_no_enqueued_jobs do
      assert_not VerifiedBot.verified?(GOOD_IP, nil)
      assert_not VerifiedBot.verified?("", GOOGLEBOT_UA)
      assert_not VerifiedBot.verified?(nil, GOOGLEBOT_UA)
    end
  end

  test "verified? on a cache miss is false and enqueues one verification" do
    assert_enqueued_with(job: VerifiedBot::VerifyIpJob, args: [ "203.0.113.9", "googlebot" ]) do
      assert_not VerifiedBot.verified?("203.0.113.9", GOOGLEBOT_UA)
    end
  end

  test "a burst of requests from one unverified IP enqueues a single job" do
    assert_enqueued_jobs 1, only: VerifiedBot::VerifyIpJob do
      5.times { VerifiedBot.verified?("203.0.113.9", GOOGLEBOT_UA) }
    end
  end

  test "a verified IP is not verified for a different engine" do
    VerifiedBot.record(GOOD_IP, "googlebot", true)
    assert_not VerifiedBot.verified?(GOOD_IP, "Mozilla/5.0 (compatible; bingbot/2.0)")
  end

  test "verified? is false rather than raising when the cache is down" do
    broken = Object.new
    broken.define_singleton_method(:read) { |*| raise Errno::ECONNREFUSED }
    broken.define_singleton_method(:write) { |*, **| raise Errno::ECONNREFUSED }
    VerifiedBot.config.cache = broken
    assert_not VerifiedBot.verified?(GOOD_IP, GOOGLEBOT_UA)
  end

  # --- check_dns ---

  test "check_dns accepts an IP whose PTR is on the engine domain and resolves back" do
    with_dns(genuine_google)
    assert VerifiedBot.check_dns(GOOD_IP, "googlebot")
  end

  test "check_dns accepts a PTR with a trailing dot and mixed case" do
    with_dns(FakeDNS.new(ptr: { GOOD_IP => "Crawl.Googlebot.COM." }, forward: { "crawl.googlebot.com" => [ GOOD_IP ] }))
    assert VerifiedBot.check_dns(GOOD_IP, "googlebot")
  end

  test "check_dns compares IPv6 addresses in canonical form" do
    with_dns(FakeDNS.new(ptr: { "2001:db8::1" => "crawl.googlebot.com" }, forward: { "crawl.googlebot.com" => [ "2001:0db8:0000:0000:0000:0000:0000:0001" ] }))
    assert VerifiedBot.check_dns("2001:db8::1", "googlebot")
  end

  test "check_dns rejects an IP with no PTR record" do
    with_dns(FakeDNS.new)
    assert_not VerifiedBot.check_dns("203.0.113.9", "googlebot")
  end

  test "check_dns rejects a PTR on someone else's domain" do
    with_dns(FakeDNS.new(ptr: { "203.0.113.9" => "scraper.example.com" }, forward: { "scraper.example.com" => [ "203.0.113.9" ] }))
    assert_not VerifiedBot.check_dns("203.0.113.9", "googlebot")
  end

  test "check_dns rejects a look-alike domain that merely ends with the engine domain" do
    with_dns(FakeDNS.new(ptr: { "203.0.113.9" => "evilgooglebot.com" }, forward: { "evilgooglebot.com" => [ "203.0.113.9" ] }))
    assert_not VerifiedBot.check_dns("203.0.113.9", "googlebot")
  end

  test "check_dns rejects a PTR on the engine domain that does not resolve back to the IP" do
    with_dns(FakeDNS.new(ptr: { "203.0.113.9" => "crawl.googlebot.com" }, forward: { "crawl.googlebot.com" => [ "66.249.66.1" ] }))
    assert_not VerifiedBot.check_dns("203.0.113.9", "googlebot")
  end

  test "check_dns raises LookupError on a DNS timeout instead of answering false" do
    with_dns(FakeDNS.new(raise_on: Timeout::Error))
    assert_raises(VerifiedBot::LookupError) { VerifiedBot.check_dns(GOOD_IP, "googlebot") }
  end
end
