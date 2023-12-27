# frozen_string_literal: true

source "https://rubygems.org"
git_source(:github) { |repo| "https://github.com/#{repo}.git" }

ruby "~> 3.2"
gem "rails"

gem "bootsnap", require: false
gem "chamber" # https://github.com/thekompanee/chamber
gem "chronic" # https://github.com/mojombo/chronic
gem "colorize" # https://github.com/fazibear/colorize
gem "cssbundling-rails" # https://github.com/rails/cssbundling-rails
gem "dotenv-rails" # https://github.com/bkeepers/dotenv
gem "google-apis-tasks_v1" # https://github.com/googleapis/google-api-ruby-client/tree/main/google-api-client/generated/google/apis/tasks_v1
gem "googleauth" # https://github.com/googleapis/google-auth-library-ruby
gem "httparty" # https://github.com/jnunemaker/httparty
gem "jsbundling-rails" # https://github.com/rails/jsbundling-rails
gem "loofah" # https://github.com/flavorjones/loofah
gem "nokogiri" # https://github.com/sparklemotion/nokogiri
gem "oauth" # https://gitlab.com/oauth-xx/oauth
gem "puma" # https://github.com/puma/puma
gem "rb-scpt" # https://github.com/BrendanThompson/rb-scpt
gem "ruby-progressbar" # https://github.com/jfelchner/ruby-progressbar
gem "sprockets-rails" # https://github.com/rails/sprockets-rails
gem "sqlite3"
gem "stimulus-rails" # https://stimulus.hotwired.dev
gem "thor" # https://github.com/rails/thor
gem "turbo-rails" # https://turbo.hotwired.dev

# Use Redis adapter to run Action Cable in production
gem "redis"

# Use Kredis to get higher-level data types in Redis [https://github.com/rails/kredis]
# gem "kredis"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
# gem "bcrypt", "~> 3.1.7"

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[mri mingw x64_mingw]
  gem "pry"
end

group :development do
  # Use console on exceptions pages [https://github.com/rails/web-console]
  gem "rubocop"
  gem "rubocop-performance"
  gem "standard"
  gem "web-console"

  # Add speed badges [https://github.com/MiniProfiler/rack-mini-profiler]
  # gem "rack-mini-profiler"

  # Speed up commands on slow machines / big apps [https://github.com/rails/spring]
  # gem "spring"
end

group :test do
  # Use system testing [https://guides.rubyonrails.org/testing.html#system-testing]
  gem "capybara"
  gem "faker" # https://github.com/faker-ruby/faker
  gem "rspec-rails"
  gem "selenium-webdriver"
end
