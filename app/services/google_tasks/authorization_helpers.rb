# frozen_string_literal: true

require "googleauth"
require "googleauth/stores/file_token_store"
require "fileutils"
require "os"

module GoogleTasks
  module AuthorizationHelpers
    OOB_URI = "urn:ietf:wg:oauth:2.0:oob"

    def client_secrets_path
      return Rails.root.join(Chamber.dig!(:google, :client_secrets_file)) if Chamber.dig(:google, :client_secrets_file)

      well_known_path_for("client_secrets.json")
    end

    def token_store_path
      return Rails.root.join(Chamber.dig!(:google, :credential_store)) if Chamber.dig(:google, :credential_store)

      well_known_path_for("credentials.yaml")
    end

    def well_known_path_for(file)
      if OS.windows?
        dir = Dir.home { ENV.fetch("APPDATA", nil) }
        File.join(dir, "google", file)
      else
        File.join(Dir.home, ".config", "google", file)
      end
    end

    def application_credentials_for(scope)
      Google::Auth.get_application_default(scope)
    end

    def user_credentials_for(scope)
      FileUtils.mkdir_p(File.dirname(token_store_path))

      client_id = if Chamber.dig(:google, :client, :id)
        Google::Auth::ClientId.new(Chamber.dig!(:google, :client, :id), Chamber.dig(:google, :client, :secret))
      else
        Google::Auth::ClientId.from_file(client_secrets_path)
      end
      token_store = Google::Auth::Stores::FileTokenStore.new(file: token_store_path)
      authorizer = Google::Auth::UserAuthorizer.new(client_id, scope, token_store)

      user_id = ENV["USER"] || "default"

      credentials = authorizer.get_credentials(user_id)
      if credentials.nil?
        url = authorizer.get_authorization_url(base_url: OOB_URI)
        prompt_user("Open the following URL in your browser and authorize the application.")
        prompt_user(url)
        code = ask_user("Enter the authorization code:")
        credentials = authorizer.get_and_store_credentials_from_code(
          user_id:, code:, base_url: OOB_URI
        )
      elsif credentials.expired?
        credentials = credentials.fetch_access_token!
        sleep 2
        raise "Google credentials have expired. Delete #{token_store_path} and re-authenticate" if credentials["expires_in"] <= 0
      end
      credentials
    end

    private

    def prompt_user(message)
      respond_to?(:say) ? say(message) : puts(message)
    end

    def ask_user(prompt)
      return ask(prompt) if respond_to?(:ask)

      print("#{prompt} ")
      $stdin.gets&.chomp
    end
  end
end
