require "test_helper"

class VerifyIpJobTest < VerifiedBotTestCase
  IP = "66.249.66.1".freeze


  def stub_check(result = nil, &block)
    stub_singleton(VerifiedBot, :check_dns) { |_ip, _engine| block ? block.call : result }
  end

  test "caches a verified IP so verified? answers true" do
    stub_check(true)
    VerifiedBot::VerifyIpJob.perform_now(IP, "googlebot")
    assert VerifiedBot.verified?(IP, "Googlebot/2.1")
  end

  test "caches a rejected IP so verified? answers false without re-enqueueing" do
    stub_check(false)
    VerifiedBot::VerifyIpJob.perform_now(IP, "googlebot")

    assert_no_enqueued_jobs do
      assert_not VerifiedBot.verified?(IP, "Googlebot/2.1")
    end
  end

  test "ignores an unknown engine name" do
    stub_check { flunk "must not run DNS for an unknown engine" }
    assert_nothing_raised { VerifiedBot::VerifyIpJob.perform_now(IP, "not-an-engine") }
    assert_nil @store.read(VerifiedBot.cache_key(IP, "not-an-engine"))
  end

  test "a DNS failure caches no verdict, so a real crawler is not marked fake" do
    stub_check { raise VerifiedBot::LookupError, "timeout" }
    perform_enqueued_jobs { VerifiedBot::VerifyIpJob.perform_later(IP, "googlebot") }

    assert_nil @store.read(VerifiedBot.cache_key(IP, "googlebot"))
  end

  test "the pending marker is cleared when retries are exhausted so a later request can retry" do
    @store.write(VerifiedBot.pending_key(IP, "googlebot"), true)
    stub_check { raise VerifiedBot::LookupError, "timeout" }

    perform_enqueued_jobs { VerifiedBot::VerifyIpJob.perform_later(IP, "googlebot") }

    assert_nil @store.read(VerifiedBot.pending_key(IP, "googlebot"))
  end
end
