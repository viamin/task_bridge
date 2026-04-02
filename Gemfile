# frozen_string_literal: true

source "https://rubygems.org"
git_source(:github) { |repo| "https://github.com/#{repo}.git" }

ruby "~> 3.4"
gem "rails"

# Ruby 3.4+ removed these from stdlib
gem "csv"
gem "bigdecimal"
gem "mutex_m"

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

# https://github.com/rails/rails/tree/main/activesupport
gem "activesupport", "~> 8.0",
  require: [
    "active_support",
    "active_support/core_ext/hash", # for reverse_merge and stringify_keys
    "active_support/core_ext/integer", # for 1.year
    "active_support/core_ext/numeric", # for 1.week
    "active_support/core_ext/object", # for try
    "active_support/core_ext/string" # for squish
  ]

# https://github.com/ruby/bigdecimal
gem "bigdecimal", "~> 4.0"

# https://github.com/ruby/base64
gem "base64", "~> 0.2"

# https://github.com/ruby/mutex_m
gem "mutex_m", "~> 0.2"

# https://github.com/ruby/csv
gem "csv", "~> 3.3"

# https://github.com/thekompanee/chamber
gem "chamber", "~> 3.0"

# https://github.com/mojombo/chronic
gem "chronic", "~> 0.10"

# https://github.com/fazibear/colorize
gem "colorize", "~> 1.0"

# https://github.com/bkeepers/dotenv
gem "dotenv", "~> 3.1", require: "dotenv/load"

# https://github.com/googleapis/google-auth-library-ruby
gem "googleauth", "~> 1.5"

# https://github.com/googleapis/google-api-ruby-client/tree/main/google-api-client/generated/google/apis/tasks_v1
gem "google-apis-tasks_v1", "~> 0.15"

# https://github.com/jnunemaker/httparty
gem "httparty", "~> 0.21"

# https://github.com/flavorjones/loofah
gem "loofah", "~> 2.20"

# https://github.com/panorama-ed/memo_wise
gem "memo_wise", "~> 1.7"

# https://github.com/sparklemotion/nokogiri
gem "nokogiri", "~> 1.14"

# https://gitlab.com/oauth-xx/oauth
gem "oauth", "~> 1.1"

# https://github.com/ManageIQ/optimist
gem "optimist", "~> 3.0"

# https://github.com/BrendanThompson/rb-scpt
gem "rb-scpt", "~> 1.0"

# https://github.com/jfelchner/ruby-progressbar
gem "ruby-progressbar", "~> 1.13"

# https://github.com/rails/thor
gem "thor", "~> 1.2"

group :development do
  gem "annotate"
  gem "rubocop"
  gem "rubocop-performance"
  gem "standard", ">= 1.35.1"
  # Use console on exceptions pages [https://github.com/rails/web-console]
  gem "web-console"

  # Add speed badges [https://github.com/MiniProfiler/rack-mini-profiler]
  # gem "rack-mini-profiler"

  # Speed up commands on slow machines / big apps [https://github.com/rails/spring]
  # gem "spring"
end

group :test do
  # Use system testing [https://guides.rubyonrails.org/testing.html#system-testing]
  gem "capybara"
  gem "faker", "~> 3.2" # https://github.com/faker-ruby/faker
  gem "rspec-rails"
  gem "selenium-webdriver"
  gem "simplecov"
end
