# frozen_string_literal: true

# Copyright 2016 Google Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require "googleauth"
require "googleauth/stores/file_token_store"
require "fileutils"
require "thor"
require "os"
require "pry"

# Base command line module for samples. Provides authorization support,
# either using application default credentials or user authorization
# depending on the use case.
module GoogleTasks
  class BaseCli < Thor
    include Thor::Actions

    OOB_URI = "urn:ietf:wg:oauth:2.0:oob"

    class_option :user, type: :string
    class_option :api_key, type: :string

    no_commands do
      # Returns the path to the client_secrets.json file.
      def client_secrets_path
        return Chamber.dig!(:google, :client_secrets_file) if Chamber.dig(:google, :client_secrets_file)

        well_known_path_for("client_secrets.json")
      end

      # Returns the path to the token store.
      def token_store_path
        return Chamber.dig!(:google, :credential_store) if Chamber.dig(:google, :credential_store)

        well_known_path_for("credentials.yaml")
      end

      # Builds a path to a file in $HOME/.config/google (or %APPDATA%/google,
      # on Windows)
      def well_known_path_for(file)
        if OS.windows?
          dir = Dir.home { ENV.fetch("APPDATA", nil) }
          File.join(dir, "google", file)
        else
          File.join(Dir.home, ".config", "google", file)
        end
      end

      # Returns application credentials for the given scope.
      def application_credentials_for(scope)
        Google::Auth.get_application_default(scope)
      end

      # Returns user credentials for the given scope. Requests authorization
      # if requrired.
      def user_credentials_for(scope)
        FileUtils.mkdir_p(File.dirname(token_store_path))

        client_id = if Chamber.dig(:google, :client, :id)
          Google::Auth::ClientId.new(Chamber.dig!(:google, :client, :id), Chamber.dig(:google, :client, :secret))
        else
          Google::Auth::ClientId.from_file(client_secrets_path)
        end
        token_store = Google::Auth::Stores::FileTokenStore.new(file: token_store_path)
        # https://github.com/googleapis/google-auth-library-ruby/blob/main/lib/googleauth/user_authorizer.rb
        authorizer = Google::Auth::UserAuthorizer.new(client_id, scope, token_store)

        user_id = ENV["USER"] || "default"

        credentials = authorizer.get_credentials(user_id)
        if credentials.nil?
          url = authorizer.get_authorization_url(base_url: OOB_URI)
          say "Open the following URL in your browser and authorize the application."
          say url
          code = ask "Enter the authorization code:"
          credentials = authorizer.get_and_store_credentials_from_code(
            user_id:, code:, base_url: OOB_URI
          )
        elsif credentials.expired?
          credentials = credentials.fetch_access_token!
          sleep 2
          # NOTE: that `fetch_access_token!` returns a Hash, not a Credentials object
          raise "Google credentials have expired. Delete #{token_store_path} and re-authenticate" if credentials["expires_in"] <= 0
        end
        credentials
      end
    end
  end
end
