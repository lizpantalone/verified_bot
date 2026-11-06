require "test_helper"

# The one-job-per-burst guarantee must hold when requests race, not just when
# they arrive one after another.
class ConcurrencyTest < VerifiedBotTestCase
  def race(count)
    gate = Queue.new
    threads = Array.new(count) { Thread.new { gate.pop; yield } }
    count.times { gate << true }
    threads.each(&:join)
  end

  test "a burst of simultaneous requests from one unverified IP enqueues one verification" do
    race(25) { VerifiedBot.verified?("203.0.113.9", "Googlebot/2.1") }
    assert_equal 1, enqueued_jobs.count { |j| j["job_class"] == "VerifiedBot::VerifyIpJob" }
  end

  test "different IPs in the same burst each get their own verification" do
    ips = Array.new(10) { |i| "203.0.113.#{i + 1}" }
    ips.each_slice(1).map { |(ip)| Thread.new { 5.times { VerifiedBot.verified?(ip, "Googlebot/2.1") } } }.each(&:join)
    assert_equal 10, enqueued_jobs.count { |j| j["job_class"] == "VerifiedBot::VerifyIpJob" }
  end

  test "a burst for a range crawler with no cached ranges enqueues one refresh" do
    race(25) { VerifiedBot.verified?("20.171.206.9", "GPTBot/1.2") }
    assert_equal 1, enqueued_jobs.count { |j| j["job_class"] == "VerifiedBot::RefreshRangesJob" }
  end

  test "readers never see a half-built range list while it is being refreshed" do
    stub_singleton(VerifiedBot, :fetch_json) { |_| { "prefixes" => [ { "ipv4Prefix" => "20.171.206.0/24" } ] } }
    VerifiedBot.refresh_ranges("gptbot")
    results = Queue.new
    writer = Thread.new { 20.times { VerifiedBot.refresh_ranges("gptbot") } }
    readers = Array.new(5) { Thread.new { 50.times { results << VerifiedBot.verified?("20.171.206.9", "GPTBot/1.2") } } }
    (readers + [ writer ]).each(&:join)
    assert_equal [ true ], Array.new(results.size) { results.pop }.uniq
  end
end
