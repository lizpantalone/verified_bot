require "test_helper"

class ConfigurationTest < VerifiedBotTestCase
  setup do
    @cache = VerifiedBot.config.cache
    @queue = VerifiedBot.config.queue
    @engines = VerifiedBot.config.engines
    VerifiedBot.config.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    VerifiedBot.config.cache = @cache
    VerifiedBot.config.queue = @queue
    VerifiedBot.config.engines = @engines
  end

  test "defaults" do
    config = VerifiedBot::Configuration.new
    assert_equal :default, config.queue
    assert_equal({}, config.engines)
    assert_match(/\Averified_bot\//, config.user_agent)
  end

  test "a custom engine is recognised and verified by its ranges" do
    VerifiedBot.config.engines = { "mybot" => { ua: /MyBot/i, ranges_url: "https://example.com/ips.json" } }
    assert_equal "mybot", VerifiedBot.claimed_engine("Mozilla MyBot/1.0")
    assert_includes VerifiedBot.range_engines, "mybot"
    assert_not VerifiedBot.verified?("203.0.113.5", "MyBot/1.0") # no ranges cached yet
  end

  test "custom engines can override a built-in" do
    VerifiedBot.config.engines = { "googlebot" => { ua: /Googlebot/i, domains: %w[example.test] } }
    assert_equal %w[example.test], VerifiedBot.engines["googlebot"][:domains]
  end

  test "jobs use the configured queue" do
    VerifiedBot.config.queue = :low
    VerifiedBot::VerifyIpJob.perform_later("203.0.113.9", "googlebot")
    assert_equal "low", enqueued_jobs.last["queue_name"]
  end

  test "an unknown engine name is ignored by the verify job" do
    assert_nil VerifiedBot::VerifyIpJob.perform_now("203.0.113.9", "nope")
    assert_nil VerifiedBot.cache.read(VerifiedBot.cache_key("203.0.113.9", "nope"))
  end
end
