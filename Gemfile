# frozen_string_literal: true

ruby '3.2.1'

source "https://rubygems.org"

# https://github.com/rails/rails/tree/main/activesupport
gem "activesupport",
    require: [
      "active_support",
      "active_support/core_ext/numeric", # for 1.week
      "active_support/core_ext/integer", # for 1.year
      "active_support/core_ext/hash", # for reverse_merge and stringify_keys
      "active_support/core_ext/string" # for squish
    ]

# https://github.com/mojombo/chronic
gem "chronic"

# https://github.com/fazibear/colorize
gem "colorize"

# https://github.com/bkeepers/dotenv
gem "dotenv", require: "dotenv/load"

# https://github.com/googleapis/google-auth-library-ruby
gem "googleauth"

# https://github.com/googleapis/google-api-ruby-client/tree/main/google-api-client/generated/google/apis/tasks_v1
gem "google-apis-tasks_v1"

# https://github.com/jnunemaker/httparty
gem "httparty"

# https://github.com/flavorjones/loofah
gem "loofah"

# https://github.com/panorama-ed/memo_wise
gem "memo_wise"

# https://github.com/sparklemotion/nokogiri
gem "nokogiri"

# https://gitlab.com/oauth-xx/oauth
gem "oauth"

# https://github.com/ManageIQ/optimist
gem "optimist"

# https://github.com/BrendanThompson/rb-scpt
gem "rb-scpt"

# https://github.com/jfelchner/ruby-progressbar
gem "ruby-progressbar"

# https://github.com/rails/thor
gem "thor"

group :development do
  gem "pry" # https://github.com/pry/pry
  gem "rubocop"
  gem "rubocop-performance"
  gem "solargraph"
  gem "standard"
end

group :test do
  gem "faker" # https://github.com/faker-ruby/faker
  gem "rspec"
end
