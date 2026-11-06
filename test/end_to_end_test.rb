require "test_helper"

# The whole flow with only DNS and HTTP faked: request -> miss -> job -> verdict.
class EndToEndTest < VerifiedBotTestCase
  GOOGLEBOT_UA = "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)".freeze

  def fake_dns(ptr:, forward:)
    with_dns(FakeDNS.new(ptr: ptr, forward: forward))
  end

  test "a real Googlebot is throttled once, then verified after the job runs" do
    fake_dns(ptr: { "66.249.66.1" => "crawl-66-249-66-1.googlebot.com" },
             forward: { "crawl-66-249-66-1.googlebot.com" => [ "66.249.66.1" ] })

    assert_not VerifiedBot.verified?("66.249.66.1", GOOGLEBOT_UA)
    perform_enqueued_jobs
    assert VerifiedBot.verified?("66.249.66.1", GOOGLEBOT_UA)
  end

  test "a scraper sending a Googlebot UA is never verified" do
    fake_dns(ptr: { "203.0.113.9" => "scraper.example.net" }, forward: { "scraper.example.net" => [ "203.0.113.9" ] })

    assert_not VerifiedBot.verified?("203.0.113.9", GOOGLEBOT_UA)
    perform_enqueued_jobs
    assert_not VerifiedBot.verified?("203.0.113.9", GOOGLEBOT_UA)
    assert_no_enqueued_jobs { VerifiedBot.verified?("203.0.113.9", GOOGLEBOT_UA) } # verdict cached
  end

  test "a PTR spoofed onto Google's domain fails the forward check" do
    fake_dns(ptr: { "203.0.113.9" => "crawl.googlebot.com" }, forward: { "crawl.googlebot.com" => [ "66.249.66.1" ] })

    assert_not VerifiedBot.verified?("203.0.113.9", GOOGLEBOT_UA)
    perform_enqueued_jobs
    assert_not VerifiedBot.verified?("203.0.113.9", GOOGLEBOT_UA)
  end

  test "a range crawler is verified after the refresh job downloads its ranges" do
    stub_singleton(VerifiedBot, :fetch_json) { |_url| { "prefixes" => [ { "ipv4Prefix" => "20.171.206.0/24" } ] } }
    ua = "Mozilla/5.0 (compatible; GPTBot/1.2; +https://openai.com/gptbot)"

    assert_not VerifiedBot.verified?("20.171.206.9", ua)
    perform_enqueued_jobs
    assert VerifiedBot.verified?("20.171.206.9", ua)
    assert_not VerifiedBot.verified?("20.171.207.9", ua)
  end

  test "verdicts expire: verified for a week, rejected for a day" do
    VerifiedBot.record("66.249.66.1", "googlebot", true)
    VerifiedBot.record("203.0.113.9", "googlebot", false)

    travel_to(Time.now + VerifiedBot::REJECTED_TTL + 1) do
      assert_nil @store.read(VerifiedBot.cache_key("203.0.113.9", "googlebot"))
      assert @store.read(VerifiedBot.cache_key("66.249.66.1", "googlebot"))
    end
    travel_to(Time.now + VerifiedBot::VERIFIED_TTL + 1) do
      assert_nil @store.read(VerifiedBot.cache_key("66.249.66.1", "googlebot"))
    end
  end

  test "cached ranges expire after RANGES_TTL so a dead feed cannot pin stale ranges forever" do
    stub_singleton(VerifiedBot, :fetch_json) { |_url| { "prefixes" => [ { "ipv4Prefix" => "20.171.206.0/24" } ] } }
    VerifiedBot.refresh_ranges("gptbot")
    assert @store.read(VerifiedBot.ranges_key("gptbot"))

    travel_to(Time.now + VerifiedBot::RANGES_TTL + 1) do
      assert_nil @store.read(VerifiedBot.ranges_key("gptbot"))
    end
  end

  test "IPv6-only range lists verify IPv6 clients (CCBot)" do
    stub_singleton(VerifiedBot, :fetch_json) { |_url| { "prefixes" => [ { "ipv6Prefix" => "2600:1f28:365:80::/60" } ] } }
    VerifiedBot.refresh_ranges("ccbot")

    assert VerifiedBot.verified?("2600:1f28:365:80::1", "CCBot/2.0")
    assert_not VerifiedBot.verified?("2600:1f28:365:90::1", "CCBot/2.0")
    assert_not VerifiedBot.verified?("20.171.206.9", "CCBot/2.0")
  end
end
