# frozen_string_literal: true

module Github
  class Authentication
    prepend MemoWise

    attr_reader :options

    def initialize(options)
      @options = options
      @authentication = nil
    end

    def authenticate!
      if missing_authentication
        auth_params = post_device_code
        puts "Go to #{auth_params['verification_uri']}\nand enter the code\n#{auth_params['user_code']}"
        @authentication = wait_for_user(auth_params)
      end
      @authentication
    end
    memo_wise :authenticate!

    private

    def check_options(auth_params)
      {
        headers: device_options[:headers],
        body: {
          client_id: Chamber.dig!(:github, :client_id),
          device_code: auth_params["device_code"],
          grant_type: "urn:ietf:params:oauth:grant-type:device_code"
        }
      }
    end

    def device_options
      {
        headers: {
          accept: "application/json"
        },
        body: {
          client_id: Chamber.dig!(:github, :client_id),
          scope: "repo"
        }
      }
    end

    def future_seconds(interval)
      Chronic.parse("#{interval} seconds from now")
    end

    def auth_file_path
      File.expand_path(File.join(__dir__, "..", "..", Chamber.dig!(:github, :access_code)))
    end
    memo_wise :auth_file_path

    def missing_authentication
      return true unless File.exist?(auth_file_path)

      @authentication = JSON.parse(File.read(auth_file_path))
      false
    end

    def post_access_token(auth_params)
      response = HTTParty.post("https://github.com/login/oauth/access_token", check_options(auth_params))
      JSON.parse(response.body)
    end

    def post_device_code
      response = HTTParty.post("https://github.com/login/device/code", device_options)
      JSON.parse(response.body)
    end

    def save_authentication(access_code)
      File.write(auth_file_path, access_code.to_json)
    end

    def wait_for_user(auth_params)
      expires_at = future_seconds(auth_params["expires_in"])
      progressbar = ProgressBar.create(total: nil)
      waiting = true
      code_check = nil
      next_interval = future_seconds(auth_params["interval"])
      while waiting && (expires_at > Time.now)
        progressbar.increment
        sleep 1
        next if next_interval > Time.now

        next_interval = future_seconds(auth_params["interval"])
        code_check = post_access_token(auth_params)
        waiting = code_check.fetch("error", false)
      end
      save_authentication(code_check) unless code_check.nil?
    end
  end
end
