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

## Protection against job floods

Every unseen IP that claims to be a crawler costs one verification job. So:

- **Cap.** At most `max_verifications_per_minute` (default 100) new jobs are
  enqueued per minute, across all IPs. A scraper rotating IPs behind a
  `Googlebot` User-Agent can't flood your queue; over the cap, requests are just
  treated as unverified, and a real crawler is verified on a later request.
  Repeat requests from one IP cost one slot, and cache hits cost none. The cap
  claims numbered slots with `unless_exist` writes rather than trusting
  `increment`, which loses updates on some stores. How exact it is depends on
  the cache store; see the table under Setup.
- **Unusable caches.** With a `NullStore` nothing can be remembered, so
  verification is disabled (and logged once) instead of enqueueing a job per
  request. A per-process `MemoryStore` in production is logged once too: job
  workers can't share verdicts with web processes through it.

## DNS handling

Ruby's `Resolv` reports a timeout or SERVFAIL as "no such record", which would
mark a real crawler as fake whenever a nameserver hiccups. So the gem has a
small DNS client (`VerifiedBot::DNS`): only NXDOMAIN or an empty answer means
"no record". A timeout, SERVFAIL, REFUSED or unreadable reply raises
`VerifiedBot::LookupError`, nothing is cached, and the job retries. It falls
back to TCP when a UDP answer is truncated, ignores replies with the wrong ID
or source, and tries each nameserver in turn.

## Setup

```ruby
gem "verified_bot", github: "lizpantalone/verified_bot"
```

In Rails, the cache and logger default to `Rails.cache` / `Rails.logger`. The
cache must be shared by your web and job processes. Elsewhere, set them yourself.

How exactly the "one job per IP" dedupe and the per-minute cap hold depends on
the store's `unless_exist` write:

| Store | Shared across processes | Dedupe and cap |
| --- | --- | --- |
| Redis | yes | exact (tested against a real Redis) |
| Memcached | yes | exact by design (`add`); not tested here |
| Solid Cache | yes | best effort: `unless_exist` locks an existing row, and a key that doesn't exist yet has none, so simultaneous requests can each win (measured: 4 jobs instead of 1, 12-13 instead of a cap of 10) |
| `FileStore` | yes | best effort, same reason |
| `MemoryStore` | no: job workers can't share verdicts, so crawlers never verify (warned about in production) | n/a |
| `NullStore` | n/a | verification disabled |

Best effort is still safe: the overshoot is limited to requests arriving in the
same instant (roughly your concurrent threads), never a flood, and an extra
verification job is idempotent. For an exact cap use Redis or Memcached.

```ruby
# config/initializers/verified_bot.rb (all optional)
VerifiedBot.configure do |c|
  c.queue = :low                  # ActiveJob queue, default :default
  c.user_agent = "mysite-bot-verifier" # sent when downloading range files
  c.nameservers = [["127.0.0.1", 53]] # reverse-DNS resolvers; default: the system's
  c.dns_timeouts = [2, 2]         # seconds per attempt, per nameserver
  c.max_verifications_per_minute = 100 # cap on new verification jobs (nil = none)
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
bundle exec rake test        # offline, any order; Redis cases need redis-server
bundle exec rake test:live   # hits the real crawler feeds; run it before a release
RAILS_VERSION=7.1 bundle update activesupport activejob railties connection_pool && bundle exec rake test
```

The suite runs the real `Resolv` and `Net::HTTP` against a local DNS server and a
local HTTPS server, so the network stack is covered without the internet.

CI runs Ruby 3.2-3.4 against Rails 7.1-8.1. The live task catches a moved feed
URL or changed format.

## License

MIT
