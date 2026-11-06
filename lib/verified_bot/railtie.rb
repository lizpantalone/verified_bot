module VerifiedBot
  class Railtie < Rails::Railtie
    initializer "verified_bot.defaults" do
      VerifiedBot.config.cache = Rails.cache
      VerifiedBot.config.logger = Rails.logger
    end
  end
end
