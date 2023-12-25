source "https://rubygems.org"
git_source(:github) { |repo| "https://github.com/#{repo}.git" }

ruby "~> 3.2"

gem "rails"
gem "sprockets-rails" # https://github.com/rails/sprockets-rails
gem "sqlite3"
gem "puma" # https://github.com/puma/puma
gem "jsbundling-rails" # https://github.com/rails/jsbundling-rails
gem "turbo-rails" # https://turbo.hotwired.dev
gem "stimulus-rails" # https://stimulus.hotwired.dev
gem "cssbundling-rails" # https://github.com/rails/cssbundling-rails
gem "bootsnap", require: false
gem "chamber" # https://github.com/thekompanee/chamber
gem "chronic" # https://github.com/mojombo/chronic
gem "colorize" # https://github.com/fazibear/colorize
gem "dotenv-rails" # https://github.com/bkeepers/dotenv
gem "googleauth" # https://github.com/googleapis/google-auth-library-ruby
gem "google-apis-tasks_v1" # https://github.com/googleapis/google-api-ruby-client/tree/main/google-api-client/generated/google/apis/tasks_v1
gem "httparty" # https://github.com/jnunemaker/httparty
gem "loofah" # https://github.com/flavorjones/loofah
gem "memo_wise" # https://github.com/panorama-ed/memo_wise
gem "nokogiri" # https://github.com/sparklemotion/nokogiri
gem "oauth" # https://gitlab.com/oauth-xx/oauth
gem "optimist" # https://github.com/ManageIQ/optimist
gem "rb-scpt" # https://github.com/BrendanThompson/rb-scpt
gem "ruby-progressbar" # https://github.com/jfelchner/ruby-progressbar
gem "thor" # https://github.com/rails/thor

# Use Redis adapter to run Action Cable in production
gem "redis"

# Use Kredis to get higher-level data types in Redis [https://github.com/rails/kredis]
# gem "kredis"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
# gem "bcrypt", "~> 3.1.7"

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[mri mingw x64_mingw]
end

group :development do
  # Use console on exceptions pages [https://github.com/rails/web-console]
  gem "web-console"
  gem "pry" # https://github.com/pry/pry
  gem "rubocop"
  gem "rubocop-performance"
  gem "standard"

  # Add speed badges [https://github.com/MiniProfiler/rack-mini-profiler]
  # gem "rack-mini-profiler"

  # Speed up commands on slow machines / big apps [https://github.com/rails/spring]
  # gem "spring"
end

group :test do
  # Use system testing [https://guides.rubyonrails.org/testing.html#system-testing]
  gem "capybara"
  gem "selenium-webdriver"
  gem "faker" # https://github.com/faker-ruby/faker
  gem "rspec"
end
