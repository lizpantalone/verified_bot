require "test_helper"
require "tmpdir"
require "socket"
require "tempfile"
require "redis"

# The same race as concurrency_test, but with separate OS processes sharing a
# real cache, which is how web workers actually run. Needs `redis-server` on
# the PATH for the Redis cases (CI installs it).
class SharedCacheTest < VerifiedBotTestCase
  PROCESSES = 12

  # Appends one line per enqueue to a file; O_APPEND keeps short writes whole.
  class FileAdapter
    def initialize(path) = @path = path

    def enqueue(job)
      File.open(@path, "a") { |f| f.write("#{job.class.name}\n") }
    end

    def enqueue_at(job, _timestamp) = enqueue(job)
  end

  def free_port
    TCPServer.open("127.0.0.1", 0) { |s| s.addr[1] }
  end

  def with_redis
    skip "redis-server not installed" unless system("which redis-server > /dev/null 2>&1")
    port = free_port
    pid = Process.spawn("redis-server", "--port", port.to_s, "--save", "", "--appendonly", "no", "--bind", "127.0.0.1",
                        out: File::NULL, err: File::NULL)
    wait_for_port(port)
    yield "redis://127.0.0.1:#{port}/0"
  ensure
    if pid
      Process.kill("TERM", pid)
      Process.wait(pid)
    end
  end

  def wait_for_port(port)
    50.times do
      TCPSocket.new("127.0.0.1", port).close
      return
    rescue SystemCallError
      sleep 0.1
    end
    flunk "redis-server did not start"
  end

  # Forks PROCESSES workers that all wait on a gate, then run the block once
  # each against a fresh cache store from the factory. Returns the enqueue log.
  def race_processes(store_factory)
    log = Tempfile.new("enqueues")
    gate_read, gate_write = IO.pipe
    pids = Array.new(PROCESSES) do
      fork do
        gate_write.close
        gate_read.read # blocks until the parent closes the pipe: a simultaneous start
        # ActiveJob's test helper sets the adapter per job class on older Rails.
        adapter = FileAdapter.new(log.path)
        [ ActiveJob::Base, VerifiedBot::VerifyIpJob, VerifiedBot::RefreshRangesJob ].each do |klass|
          klass.disable_test_adapter if klass.respond_to?(:disable_test_adapter)
          klass.queue_adapter = adapter
        end
        VerifiedBot.config.cache = store_factory.call
        yield
        exit!(0)
      rescue Exception => e # rubocop:disable Lint/RescueException
        warn "child failed: #{e.class}: #{e.message}"
        exit!(1)
      end
    end
    gate_read.close
    gate_write.close
    statuses = pids.map { |pid| Process.wait2(pid).last }
    assert statuses.all?(&:success?), "a worker process crashed"
    File.readlines(log.path, chomp: true)
  ensure
    log&.close!
  end

  test "Redis: simultaneous requests from separate processes enqueue one verification" do
    with_redis do |url|
      enqueued = race_processes(-> { ActiveSupport::Cache::RedisCacheStore.new(url: url) }) do
        VerifiedBot.verified?("203.0.113.9", "Googlebot/2.1")
      end
      assert_equal [ "VerifiedBot::VerifyIpJob" ], enqueued
    end
  end

  test "Redis: simultaneous requests from separate processes enqueue one range refresh" do
    with_redis do |url|
      enqueued = race_processes(-> { ActiveSupport::Cache::RedisCacheStore.new(url: url) }) do
        VerifiedBot.verified?("20.171.206.9", "GPTBot/1.2")
      end
      assert_equal [ "VerifiedBot::RefreshRangesJob" ], enqueued
    end
  end

  test "Redis: a verdict recorded by one process is visible to another" do
    with_redis do |url|
      writer = ActiveSupport::Cache::RedisCacheStore.new(url: url)
      reader = ActiveSupport::Cache::RedisCacheStore.new(url: url)
      VerifiedBot.config.cache = writer
      VerifiedBot.record("66.249.66.1", "googlebot", true)
      VerifiedBot.config.cache = reader
      assert VerifiedBot.verified?("66.249.66.1", "Googlebot/2.1")
    end
  end

  test "Redis: ranges cached by one process are used by another, TTL included" do
    with_redis do |url|
      stub_singleton(VerifiedBot, :fetch_json) { |_| { "prefixes" => [ { "ipv4Prefix" => "20.171.206.0/24" } ] } }
      VerifiedBot.config.cache = ActiveSupport::Cache::RedisCacheStore.new(url: url)
      VerifiedBot.refresh_ranges("gptbot")

      VerifiedBot.config.cache = ActiveSupport::Cache::RedisCacheStore.new(url: url)
      VerifiedBot.reset_range_memo!
      assert VerifiedBot.verified?("20.171.206.9", "GPTBot/1.2")
      ttl = Redis.new(url: url).ttl("verified_bot:ranges:gptbot")
      assert_in_delta VerifiedBot::RANGES_TTL.to_i, ttl, 60
    end
  end

  test "Redis: the cache going away mid-flight fails closed, never raising" do
    with_redis do |url|
      VerifiedBot.config.cache = ActiveSupport::Cache::RedisCacheStore.new(url: url, error_handler: ->(**) { raise "boom" })
    end # server stopped here
    assert_equal false, VerifiedBot.verified?("66.249.66.1", "Googlebot/2.1")
  end

  # FileStore's unless_exist is not atomic across processes (Rails limitation),
  # so duplicates are possible there, but an enqueue must never be lost.
  test "FileStore: processes may duplicate the enqueue but never lose it" do
    Dir.mktmpdir do |dir|
      enqueued = race_processes(-> { ActiveSupport::Cache::FileStore.new(dir) }) do
        VerifiedBot.verified?("203.0.113.9", "Googlebot/2.1")
      end
      assert_operator enqueued.size, :>=, 1
      assert_equal [ "VerifiedBot::VerifyIpJob" ], enqueued.uniq
    end
  end
end
