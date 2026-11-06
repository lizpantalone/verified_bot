source "https://rubygems.org"
gemspec

if ENV["RAILS_VERSION"]
  gem "activesupport", "~> #{ENV["RAILS_VERSION"]}.0"
  gem "activejob", "~> #{ENV["RAILS_VERSION"]}.0"
end
gem "railties" # for the Railtie test
gem "redis", ">= 4.0.1" # shared-cache concurrency test
gem "connection_pool", "< 3" # Rails < 8.1 breaks on connection_pool 3
gem "rake"
gem "minitest", "~> 5.25"
gem "rubocop-rails-omakase", require: false
