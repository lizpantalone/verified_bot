require_relative "lib/verified_bot/version"

Gem::Specification.new do |spec|
  spec.name = "verified_bot"
  spec.version = VerifiedBot::VERSION
  spec.authors = [ "Liz Pantalone" ]
  spec.summary = "Verify that a request really comes from the crawler its User-Agent claims."
  spec.description = "A User-Agent proves nothing. verified_bot checks the client IP the way " \
                     "crawler operators document it (reverse DNS, or their published IP ranges) " \
                     "without ever doing DNS or HTTP in the request path."
  spec.homepage = "https://github.com/lizpantalone/verified_bot"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"
  spec.files = Dir["lib/**/*", "README.md", "LICENSE.txt", "CHANGELOG.md"]
  spec.require_paths = [ "lib" ]
  spec.add_dependency "activesupport", ">= 7.1", "< 9"
  spec.add_dependency "resolv", ">= 0.3.0" # raise_timeout_errors
  spec.add_dependency "activejob", ">= 7.1", "< 9"
  spec.metadata["rubygems_mfa_required"] = "true"
end
