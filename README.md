# verified_bot

A `User-Agent` proves nothing: any scraper can send `Googlebot`. `verified_bot`
checks the client IP the way each crawler operator documents it, so you can let
real crawlers past your throttles and keep fakes throttled.

Two methods, matching what each operator publishes:

- **Reverse DNS** (forward-confirmed): Googlebot, Bingbot, Baidu, Yandex, Applebot.
- **Published IP ranges**: GPTBot, OAI-SearchBot, ChatGPT-User, PerplexityBot,
  Perplexity-User, CCBot, DuckDuckBot, and Anthropic (ClaudeBot, Claude-SearchBot,
  Claude-User).

Crawlers that publish neither (Bytespider, Meta's crawlers) get no bypass.

## The request path never does I/O

`VerifiedBot.verified?(ip, user_agent)` only reads the cache.

- A cached verdict answers immediately.
- A miss answers `false` (treat the request like any visitor) and enqueues one
  ActiveJob to do the DNS lookup, so the next request is answered.
- Published ranges are downloaded by a job and cached. Bad, oversized, too-broad
  or unreachable range files never replace the last good list.
- DNS timeouts are retried, never cached as "fake".

It never raises: a cache failure returns `false`.

## Setup

```ruby
gem "verified_bot", github: "lizpantalone/verified_bot"
```

In Rails, the cache and logger default to `Rails.cache` / `Rails.logger`. The
cache must be shared by your web and job processes (Solid Cache, Redis, Memcached;
not a per-process memory store). Elsewhere, set them yourself.

```ruby
# config/initializers/verified_bot.rb (all optional)
VerifiedBot.configure do |c|
  c.queue = :low                  # ActiveJob queue, default :default
  c.user_agent = "mysite-bot-verifier" # sent when downloading range files
  c.engines = {                   # add or override engines
    "mybot" => { ua: /MyBot/i, ranges_url: "https://example.com/ips.json" }
    # or: { ua: /MyBot/i, domains: %w[mybot.example] }  # reverse DNS
  }
end
```

Refresh published ranges daily. With Solid Queue (`config/recurring.yml`):

```yaml
production:
  refresh_bot_ip_ranges:
    class: VerifiedBot::RefreshRangesJob
    schedule: at 4am every day
```

Entries live in the cache for 3 days, so two failed refreshes are survivable. A
missing list is also fetched on demand the first time a matching request arrives.

## Usage with Rack::Attack

```ruby
class Rack::Attack
  def self.verified_bot?(req)
    VerifiedBot.verified?(client_ip(req), req.user_agent)
  end

  throttle("requests/ip", limit: 300, period: 5.minutes) do |req|
    client_ip(req) unless verified_bot?(req)
  end
end
```

Use the real client IP (e.g. `CF-Connecting-IP` behind Cloudflare), not the
proxy's. The gem has no Rack::Attack dependency; it is just a predicate.

## Other API

```ruby
VerifiedBot.claimed_engine(ua)  # => "googlebot" or nil (what the UA claims)
VerifiedBot.check_dns(ip, "googlebot") # => true/false, raises VerifiedBot::LookupError on DNS failure
VerifiedBot.refresh_ranges("gptbot")   # => prefix count
```

## Development

```
bundle install
bundle exec rake test
```

## License

MIT
