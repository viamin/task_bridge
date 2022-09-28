module Github
  # A service class to connect to the Github API
  class Service
    attr_reader :options, :authentication

    def initialize(options)
      @options = options
      @authentication = authenticate
      puts @authentication if options[:verbose]
    end

    def authenticate
      auth_params = post_device_code
      puts "Go to #{auth_params["verification_uri"]}\nand enter the code\n#{auth_params["user_code"]}"
      wait_for_user(auth_params)
    end

    def wait_for_user(auth_params)
      expires_at = future_seconds(auth_params["expires_in"])
      progressbar = ProgressBar.create(total: nil)
      waiting = true
      next_interval = future_seconds(auth_params["interval"])
      while waiting && (expires_at > Time.now)
        progressbar.increment
        sleep 1
        next if next_interval > Time.now

        next_interval = future_seconds(auth_params["interval"])
        code_check = post_access_token(auth_params)
        waiting = code_check.fetch("error", false)
      end
      code_check
    end

    def list_repositories
      response = HTTParty.get("https://api.github.com/user/repos", authenticated_options)
      JSON.parse(response.body)
    end

    def list_issues(repository)
      response = HTTParty.get("https://api.github.com/repos/#{repository}/issues", authenticated_options)
      JSON.parse(response.body)
    end

    private

    def authenticated_options
      {
        headers: {
          accept: "application/vnd.github+json",
          authorization: "Bearer #{authentication["access_token"]}"
        }
      }
    end

    def future_seconds(interval)
      Chronic.parse("#{interval} seconds from now")
    end

    def post_device_code
      response = HTTParty.post("https://github.com/login/device/code", device_options)
      JSON.parse(response.body)
    end

    def device_options
      {
        headers: {
          accept: "application/json"
        },
        body: {
          client_id: ENV.fetch("GITHUB_CLIENT_ID"),
          scope: "repo"
        }
      }
    end

    def post_access_token(auth_params)
      response = HTTParty.post("https://github.com/login/oauth/access_token", check_options(auth_params))
      JSON.parse(response.body)
    end

    def check_options(auth_params)
      {
        headers: device_options[:headers],
        body: {
          client_id: ENV.fetch("GITHUB_CLIENT_ID"),
          device_code: auth_params["device_code"],
          grant_type: "urn:ietf:params:oauth:grant-type:device_code"
        }
      }
    end
  end
end
