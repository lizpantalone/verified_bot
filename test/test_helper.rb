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

# Tests were written against ActiveSupport::TestCase (test/setup/assert_not).
VerifiedBotTestCase = ActiveSupport::TestCase
