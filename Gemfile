# frozen_string_literal: true

ruby "~> 3.1"

source "https://rubygems.org"

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
  gem "pry" # https://github.com/pry/pry
  gem "rubocop"
  gem "rubocop-performance"
  gem "standard"
end

group :test do
  gem "faker", "~> 3.2" # https://github.com/faker-ruby/faker
  gem "rspec", "~> 3.10"
end
