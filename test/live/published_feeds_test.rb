require "test_helper"

# Opt-in (rake test:live): hits the real operator feeds to catch a moved
# URL or a changed format before users do. Not part of the default run.
class PublishedFeedsTest < VerifiedBotTestCase
  VerifiedBot::ENGINES.select { |_n, c| c[:ranges_url] }.each do |name, cfg|
    test "#{name} feed is reachable and parses" do
      assert_operator VerifiedBot.refresh_ranges(name), :>, 0, cfg[:ranges_url]
    end
  end

  VerifiedBot::ENGINES.select { |_n, c| c[:domains] }.each do |name, cfg|
    test "#{name} reverse DNS domains still exist" do
      assert cfg[:domains].any? { |d| Resolv::DNS.open { |r| r.getaddresses(d).any? || r.getresources(d, Resolv::DNS::Resource::IN::NS).any? } }, cfg[:domains].inspect
    end
  end
end
