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

    # Resolvers for the reverse-DNS check, as [[host, port], ...]. Default: the
    # system resolvers. Useful for pointing at a fast local cache or 1.1.1.1.
    attr_accessor :nameservers

    # Seconds to wait for each reverse-DNS attempt per nameserver: one entry
    # per attempt. Default: two attempts of 2 seconds.
    attr_accessor :dns_timeouts

    # Cap on new verification jobs per minute, across all IPs (nil = no cap).
    # Each unseen IP that claims to be a crawler costs one job, so a scraper
    # rotating IPs behind a Googlebot User-Agent could otherwise enqueue one
    # job per request. Over the cap, requests are simply treated as unverified
    # and a real crawler is verified on a later request.
    attr_accessor :max_verifications_per_minute

    def initialize
      @cache = ActiveSupport::Cache::MemoryStore.new
      @logger = nil
      @queue = :default
      @user_agent = "verified_bot/#{VERSION}"
      @engines = {}
      @nameservers = nil
      @dns_timeouts = [ 2, 2 ]
      @max_verifications_per_minute = 100
    end
  end
end
