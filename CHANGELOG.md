# Changelog

## 0.1.0

- Own DNS client: timeouts, SERVFAIL and REFUSED are errors, never cached as "not a crawler"; TCP fallback; spoof checks; `config.nameservers`, `config.dns_timeouts`.
- Dual-stack `::ffff:a.b.c.d` clients match their IPv4 PTR/A records.
- Tested on Ruby 3.3/3.4 and Rails 7.1-8.1; live-feed check via `rake test:live`.
- Extracted from LizPlants (garden_planner): reverse-DNS and published-range verification, ActiveJob workers, configurable cache, queue and engines.
