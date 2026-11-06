require "test_helper"
require "open3"
require "rbconfig"

# Boots a minimal Rails app in a subprocess (rails must load before the gem,
# as it does under Bundler.require) and checks the defaults the Railtie sets.
class RailtieTest < VerifiedBotTestCase
  SCRIPT = <<~'RUBY'
    require "rails"
    require "verified_bot"
    class DummyApp < Rails::Application
      config.eager_load = false
      config.logger = Logger.new(nil)
      config.cache_store = :memory_store
      config.secret_key_base = "x"
    end
    Rails.application.initialize!
    puts VerifiedBot.config.cache.equal?(Rails.cache)
    puts VerifiedBot.config.logger.equal?(Rails.logger)
  RUBY

  test "in a Rails app the cache and logger default to Rails.cache and Rails.logger" do
    out, err, status = Open3.capture3(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", SCRIPT)
    assert status.success?, err
    assert_equal %w[true true], out.split
  end

  test "outside Rails the defaults are a private memory store and no logger" do
    config = VerifiedBot::Configuration.new
    assert_kind_of ActiveSupport::Cache::MemoryStore, config.cache
    assert_nil config.logger
  end
end
