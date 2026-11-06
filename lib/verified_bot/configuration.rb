module VerifiedBot
  class Configuration
    # Where verdicts and published ranges are stored. Defaults to Rails.cache
    # in a Rails app (set by the Railtie). Must be shared between web and job
    # processes, so not a per-process MemoryStore in production.
    attr_accessor :cache

    # Logger for warnings (cache failures, refresh problems).
    attr_accessor :logger

    # ActiveJob queue for the verification and refresh jobs.
    attr_accessor :queue

    # User-Agent sent when downloading published IP ranges.
    attr_accessor :user_agent

    # Extra engines, merged over the built-ins. Same shape as ENGINES:
    #   "mybot" => { ua: /MyBot/i, domains: %w[mybot.example] }       # reverse DNS
    #   "mybot" => { ua: /MyBot/i, ranges_url: "https://.../ips.json" } # IP ranges
    attr_accessor :engines

    def initialize
      @cache = ActiveSupport::Cache::MemoryStore.new
      @logger = nil
      @queue = :default
      @user_agent = "verified_bot/#{VERSION}"
      @engines = {}
    end
  end
end
