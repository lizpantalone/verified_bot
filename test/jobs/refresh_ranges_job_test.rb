require "test_helper"

class VerifiedBot::RefreshRangesJobTest < ActiveJob::TestCase
  setup do
    @original_cache = VerifiedBot.config.cache
    @store = ActiveSupport::Cache::MemoryStore.new
    store = @store
    VerifiedBot.config.cache = store
    @original_refresh = VerifiedBot.method(:refresh_ranges)
    @refreshed = []
  end

  teardown do
    VerifiedBot.config.cache = @original_cache
    VerifiedBot.define_singleton_method(:refresh_ranges, @original_refresh)
  end

  def stub_refresh(failing: [])
    refreshed = @refreshed
    VerifiedBot.define_singleton_method(:refresh_ranges) do |engine|
      refreshed << engine
      raise VerifiedBot::LookupError, "#{engine} down" if failing.include?(engine)

      3
    end
  end

  test "with no argument it refreshes every ranges engine" do
    stub_refresh
    VerifiedBot::RefreshRangesJob.perform_now
    assert_equal VerifiedBot.range_engines, @refreshed
  end

  test "with an engine it refreshes only that engine" do
    stub_refresh
    VerifiedBot::RefreshRangesJob.perform_now("gptbot")
    assert_equal [ "gptbot" ], @refreshed
  end

  test "an unknown or reverse-DNS engine is ignored" do
    stub_refresh
    assert_nothing_raised do
      VerifiedBot::RefreshRangesJob.perform_now("nope")
      VerifiedBot::RefreshRangesJob.perform_now("googlebot")
    end
    assert_empty @refreshed
  end

  test "one operator being down does not stop the others, and the run is retried" do
    stub_refresh(failing: [ "gptbot" ])
    assert_enqueued_jobs 1, only: VerifiedBot::RefreshRangesJob do
      VerifiedBot::RefreshRangesJob.perform_now
    end
    assert_equal VerifiedBot.range_engines, @refreshed
  end

  test "giving up after retries clears the pending marker so a later request can retry" do
    stub_refresh(failing: [ "gptbot" ])
    @store.write("verified_bot:ranges_pending:gptbot", true)

    perform_enqueued_jobs { VerifiedBot::RefreshRangesJob.perform_later("gptbot") }

    assert_nil @store.read("verified_bot:ranges_pending:gptbot")
    assert_equal 3, @refreshed.size
  end

  test "a successful refresh keeps the pending marker until it expires" do
    stub_refresh
    @store.write("verified_bot:ranges_pending:gptbot", true)
    VerifiedBot::RefreshRangesJob.perform_now("gptbot")
    assert @store.read("verified_bot:ranges_pending:gptbot")
  end
end
