require "test_helper"
require "stringio"

# The cap on new verification jobs, and the guards for caches that can't work.
class BudgetTest < VerifiedBotTestCase
  UA = "Mozilla/5.0 (compatible; Googlebot/2.1)".freeze

  def verification_jobs
    enqueued_jobs.count { |j| j["job_class"] == "VerifiedBot::VerifyIpJob" }
  end

  def spoofers(count)
    Array.new(count) { |i| "10.#{i / 250}.#{i % 250}.1" }
  end

  def capture_log
    io = StringIO.new
    VerifiedBot.config.logger = Logger.new(io)
    io
  end

  # --- the cap ---

  test "the default cap is 100 new verifications a minute" do
    assert_equal 100, VerifiedBot::Configuration.new.max_verifications_per_minute
  end

  test "an IP-rotating spoofer cannot enqueue more jobs than the cap" do
    1000.times.map { |i| "10.#{i / 250}.#{i % 250}.1" }.each { |ip| VerifiedBot.verified?(ip, UA) }
    assert_equal 100, verification_jobs
  end

  test "the cap is configurable" do
    VerifiedBot.config.max_verifications_per_minute = 5
    spoofers(50).each { |ip| VerifiedBot.verified?(ip, UA) }
    assert_equal 5, verification_jobs
  end

  test "nil means no cap" do
    VerifiedBot.config.max_verifications_per_minute = nil
    spoofers(300).each { |ip| VerifiedBot.verified?(ip, UA) }
    assert_equal 300, verification_jobs
  end

  test "zero disables new verifications entirely" do
    VerifiedBot.config.max_verifications_per_minute = 0
    spoofers(10).each { |ip| assert_not VerifiedBot.verified?(ip, UA) }
    assert_equal 0, verification_jobs
  end

  test "requests over the cap are unverified, not errors" do
    VerifiedBot.config.max_verifications_per_minute = 1
    VerifiedBot.verified?("203.0.113.1", UA)
    assert_equal false, VerifiedBot.verified?("203.0.113.2", UA)
  end

  test "the budget resets every minute" do
    VerifiedBot.config.max_verifications_per_minute = 3
    spoofers(10).each { |ip| VerifiedBot.verified?(ip, UA) }
    assert_equal 3, verification_jobs

    travel_to(Time.now + 61) do
      spoofers(10).each { |ip| VerifiedBot.verified?(ip, UA) }
    end
    assert_equal 6, verification_jobs
  end

  test "an IP turned away over the cap is retried on a later request, not locked out for ten minutes" do
    VerifiedBot.config.max_verifications_per_minute = 1
    VerifiedBot.verified?("203.0.113.1", UA)
    VerifiedBot.verified?("66.249.66.1", UA) # over the cap
    assert_nil @store.read(VerifiedBot.pending_key("66.249.66.1", "googlebot"))

    travel_to(Time.now + 61) { VerifiedBot.verified?("66.249.66.1", UA) }
    assert_equal 2, verification_jobs
  end

  test "repeat requests from one IP cost one slot, not one each" do
    VerifiedBot.config.max_verifications_per_minute = 2
    50.times { VerifiedBot.verified?("203.0.113.1", UA) }
    VerifiedBot.verified?("203.0.113.2", UA)
    assert_equal 2, verification_jobs
  end

  test "cache hits and non-crawler requests use no budget" do
    VerifiedBot.config.max_verifications_per_minute = 1
    VerifiedBot.record("66.249.66.1", "googlebot", true)
    20.times { assert VerifiedBot.verified?("66.249.66.1", UA) }
    20.times { VerifiedBot.verified?("203.0.113.9", "Mozilla/5.0 Firefox/140.0") }
    VerifiedBot.verified?("203.0.113.1", UA)
    assert_equal 1, verification_jobs
  end

  test "range refreshes are not limited by the verification cap" do
    VerifiedBot.config.max_verifications_per_minute = 0
    VerifiedBot.verified?("20.171.206.9", "GPTBot/1.2")
    assert_equal 1, enqueued_jobs.count { |j| j["job_class"] == "VerifiedBot::RefreshRangesJob" }
  end

  test "hitting the cap is logged once" do
    log = capture_log
    VerifiedBot.config.max_verifications_per_minute = 2
    spoofers(20).each { |ip| VerifiedBot.verified?(ip, UA) }
    assert_equal 1, log.string.scan("over 2 new verifications/minute").size
  end

  test "simultaneous spoofers on many threads still respect the cap exactly" do
    VerifiedBot.config.max_verifications_per_minute = 10
    gate = Queue.new
    threads = spoofers(60).map { |ip| Thread.new { gate.pop; VerifiedBot.verified?(ip, UA) } }
    60.times { gate << true }
    threads.each(&:join)
    assert_equal 10, verification_jobs
  end

  # A store whose counter is always stale, the worst case for a racy increment.
  class StaleCounterStore < ActiveSupport::Cache::MemoryStore
    def increment(*_args, **_opts) = 1
  end

  test "the cap is exact even when the cache's increment loses every update" do
    VerifiedBot.config.cache = StaleCounterStore.new
    VerifiedBot.config.max_verifications_per_minute = 10
    spoofers(80).each { |ip| VerifiedBot.verified?(ip, UA) }
    assert_equal 10, verification_jobs
  end

  test "the cap is exact under threads when the increment is stale" do
    VerifiedBot.config.cache = StaleCounterStore.new
    VerifiedBot.config.max_verifications_per_minute = 10
    gate = Queue.new
    threads = spoofers(60).map { |ip| Thread.new { gate.pop; VerifiedBot.verified?(ip, UA) } }
    60.times { gate << true }
    threads.each(&:join)
    assert_equal 10, verification_jobs
  end

  test "a cache that cannot count fails closed" do
    store = ActiveSupport::Cache::MemoryStore.new
    store.define_singleton_method(:increment) { |*_a, **_k| nil }
    VerifiedBot.config.cache = store
    spoofers(10).each { |ip| VerifiedBot.verified?(ip, UA) }
    assert_operator verification_jobs, :<=, 1 # never exceeds what it could count
  end

  test "a failing cache returns false and enqueues nothing" do
    broken = Object.new
    %i[read write increment delete].each { |m| broken.define_singleton_method(m) { |*_a, **_k| raise Errno::ECONNREFUSED } }
    VerifiedBot.config.cache = broken
    assert_equal false, VerifiedBot.verified?("203.0.113.1", UA)
    assert_equal 0, verification_jobs
  end

  # --- caches that cannot work ---

  test "a NullStore never enqueues verification jobs" do
    VerifiedBot.config.cache = ActiveSupport::Cache::NullStore.new
    20.times { assert_not VerifiedBot.verified?("203.0.113.9", UA) }
    assert_equal 0, verification_jobs
  end

  test "a NullStore never enqueues range refreshes" do
    VerifiedBot.config.cache = ActiveSupport::Cache::NullStore.new
    20.times { VerifiedBot.verified?("20.171.206.9", "GPTBot/1.2") }
    assert_equal 0, enqueued_jobs.size
  end

  test "a NullStore is reported once" do
    log = capture_log
    VerifiedBot.config.cache = ActiveSupport::Cache::NullStore.new
    5.times { VerifiedBot.verified?("203.0.113.9", UA) }
    assert_equal 1, log.string.scan("NullStore").size
  end

  test "a per-process MemoryStore in production is reported once, but still works" do
    log = capture_log
    stub_singleton(VerifiedBot, :production?) { true }
    5.times { |i| VerifiedBot.verified?("203.0.113.#{i}", UA) }
    assert_equal 1, log.string.scan("per-process MemoryStore").size
    assert_equal 5, verification_jobs
  end

  test "a MemoryStore outside production is not reported" do
    log = capture_log
    VerifiedBot.verified?("203.0.113.1", UA)
    assert_empty log.string
  end

  test "a shared store is not reported" do
    log = capture_log
    VerifiedBot.config.cache = ActiveSupport::Cache::FileStore.new(Dir.mktmpdir)
    stub_singleton(VerifiedBot, :production?) { true }
    VerifiedBot.verified?("203.0.113.1", UA)
    assert_empty log.string
  end
end
