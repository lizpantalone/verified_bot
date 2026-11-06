module VerifiedBot
  # Runs the reverse/forward DNS check for an IP claiming to be a crawler and
  # stores the answer where VerifiedBot.verified? reads it.
  class VerifyIpJob < ActiveJob::Base
    queue_as { VerifiedBot.config.queue }

    # DNS flaked: try again shortly, and cache nothing meanwhile so a real
    # Googlebot isn't marked fake because of a timeout.
    retry_on VerifiedBot::LookupError, wait: 30.seconds, attempts: 3 do |job, _error|
      ip, engine = job.arguments
      VerifiedBot.clear_pending(ip, engine)
    end

    def perform(ip, engine)
      return unless VerifiedBot.engines.key?(engine)

      VerifiedBot.record(ip, engine, VerifiedBot.check_dns(ip, engine))
    end
  end

  # Downloads the IP ranges crawler operators publish and caches them. Schedule
  # it daily; it is also enqueued on demand when a request claims to be a
  # crawler whose ranges aren't cached yet.
  class RefreshRangesJob < ActiveJob::Base
    queue_as { VerifiedBot.config.queue }

    # On giving up, clear the pending marker so a later request can enqueue a
    # new attempt. A failed refresh never touches the last good ranges.
    retry_on VerifiedBot::LookupError, wait: 1.minute, attempts: 3 do |job, error|
      VerifiedBot.config.logger&.warn("[VerifiedBot::RefreshRangesJob] giving up: #{error.message}")
      Array(job.arguments.first || VerifiedBot.range_engines).each do |engine|
        VerifiedBot.clear_ranges_pending(engine)
      end
    end

    # With no argument, refreshes every engine. One operator's outage must not
    # stop the others, so failures are collected and the first is re-raised last.
    def perform(engine = nil)
      engines = engine ? [ engine ] : VerifiedBot.range_engines
      errors = []

      engines.each do |name|
        next unless VerifiedBot.range_engines.include?(name)

        count = VerifiedBot.refresh_ranges(name)
        VerifiedBot.config.logger&.info("[VerifiedBot::RefreshRangesJob] #{name}: #{count} prefixes")
      rescue VerifiedBot::LookupError => e
        VerifiedBot.config.logger&.warn("[VerifiedBot::RefreshRangesJob] #{name}: #{e.message}")
        errors << e
      end

      raise errors.first if errors.any?
    end
  end
end
