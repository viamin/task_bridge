# frozen_string_literal: true

require "oauth"

module Instapaper
  class Authentication
    prepend MemoWise
    include Debug

    attr_reader :options

    def initialize(options)
      @options = options
    end

    def authenticate!
      debug("Called") if options[:debug]
      params = {
        site: "https://www.instapaper.com/api/1",
        scheme: :header,
        http_method: :post,
        access_token_path: "/oauth/access_token",
        body_hash_enabled: false
      }
      consumer = OAuth::Consumer.new(credentials[:key], credentials[:secret], params)
      request_options = {}
      arguments = {
        x_auth_username: credentials[:username],
        x_auth_password: credentials[:password],
        x_auth_mode: "client_auth"
      }
      consumer.get_access_token(nil, request_options, arguments)
    end
    memo_wise :authenticate!

    private

    def credentials
      {
        key: ENV.fetch("INSTAPAPER_OAUTH_CONSUMER_ID"),
        secret: ENV.fetch("INSTAPAPER_OAUTH_CONSUMER_SECRET"),
        username: ENV.fetch("INSTAPAPER_USERNAME"),
        password: ENV.fetch("INSTAPAPER_PASSWORD")
      }
    end
  end
end
