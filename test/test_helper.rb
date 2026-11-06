$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "active_support"
require "active_support/rails"
require "active_support/test_case"
require "minitest/autorun"
require "active_job"
require "active_job/test_helper"
require "logger"
require "verified_bot"

ActiveJob::Base.queue_adapter = :test
ActiveJob::Base.logger = Logger.new(nil)

# Scripted DNS: ptr maps ip => hostname, forward maps hostname => [ips];
# `fail: true` simulates a nameserver that can't be reached.
class FakeDNS
  def initialize(ptr: {}, forward: {}, fail: false)
    @ptr, @forward, @fail = ptr, forward, fail
  end

  def ptr(ip)
    raise VerifiedBot::LookupError, "timed out" if @fail

    @ptr[ip.to_s]
  end

  def addresses(host)
    raise VerifiedBot::LookupError, "timed out" if @fail

    @forward.fetch(host, [])
  end
end

# Every test starts from a fresh config, an empty cache and no parsed-range
# memo, and any stub it installs is undone afterwards, so tests pass in any
# order and leave nothing behind.
class VerifiedBotTestCase < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @saved_config = VerifiedBot.instance_variable_get(:@config)
    VerifiedBot.instance_variable_set(:@config, VerifiedBot::Configuration.new)
    @store = ActiveSupport::Cache::MemoryStore.new
    VerifiedBot.config.cache = @store
    VerifiedBot.reset_range_memo!
    @stubs = []
  end

  teardown do
    @stubs.reverse_each do |obj, name, original|
      obj.singleton_class.send(:remove_method, name)
      obj.define_singleton_method(name, original) if original
    end
    VerifiedBot.instance_variable_set(:@config, @saved_config)
    VerifiedBot.reset_range_memo!
  end

  def with_dns(fake)
    stub_singleton(VerifiedBot::DNS, :ptr) { |ip| fake.ptr(ip) }
    stub_singleton(VerifiedBot::DNS, :addresses) { |host| fake.addresses(host) }
  end

  # Replace a singleton method for the length of one test, then restore it.
  def stub_singleton(obj, name, &impl)
    sc = obj.singleton_class
    own = sc.instance_methods(false).include?(name) || sc.private_instance_methods(false).include?(name)
    original = own ? obj.method(name) : nil
    sc.send(:remove_method, name) if own
    obj.define_singleton_method(name, &impl)
    @stubs << [ obj, name, original ]
  end
end
