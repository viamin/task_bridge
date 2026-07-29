# frozen_string_literal: true

require "cgi"
require "ipaddr"
require "json"
require "net/http"
require "openssl"
require "securerandom"
require "socket"
require "uri"

module Omnifocus
  module Web
    class Client
      class AuthenticationError < StandardError; end
      class ConnectionError < StandardError; end

      attr_reader :account, :password, :server_label, :locale

      def initialize(credentials:, options: nil, transport: nil)
        @account = credentials.fetch(:account)
        @password = credentials.fetch(:password)
        @server_label = credentials[:server_label]
        @locale = credentials[:locale]
        @options = options || {}
        @transport = transport || Transport.new(
          account:,
          password:,
          server_label:,
          locale:
        )
      end

      def document
        @document ||= Document.new(transport: @transport)
      end

      class Document
        def initialize(transport:)
          @transport = transport
        end

        def inbox_tasks
          @inbox_tasks ||= Collection.new(@transport.load_collection(container: "inbox"), transport: @transport)
        end

        def flattened_tags
          @flattened_tags ||= Lookup.new(@transport.load_lookup(container: "tags"), key: :name, transport: @transport)
        end

        def flattened_tasks
          @flattened_tasks ||= Lookup.new(@transport.load_lookup(container: "tasks"), transport: @transport)
        end

        def flattened_projects
          @flattened_projects ||= Lookup.new(@transport.load_lookup(container: "projects"), transport: @transport)
        end

        def flattened_folders
          @flattened_folders ||= Lookup.new(@transport.load_lookup(container: "folders"), transport: @transport)
        end

        def make(new:, with_properties:)
          Reference.new(@transport.create_item(kind: new, properties: with_properties), transport: @transport)
        end

        def add(tag, to:)
          @transport.add_tag(tag:, to:)
        end
      end

      class Lookup
        def initialize(items, key: :name, transport: nil)
          @items_by_key = Array(items).each_with_object({}) do |item, index|
            reference = item.is_a?(Reference) ? item : Reference.new(item, transport:)
            name = reference.name.get
            index[name] = reference if name.present?
            external_id = reference.external_id
            index[external_id] = reference if external_id.present?
            key_value = reference.public_send(key).get if reference.respond_to?(key)
            index[key_value] = reference if key_value.present?
          end
        end

        def [](value)
          @items_by_key[value]
        end

        def find_by_id(value)
          @items_by_key[value]
        end
      end

      class Collection
        def initialize(items, transport: nil)
          @items = Array(items).map { |item| item.is_a?(Reference) ? item : Reference.new(item, transport:) }
        end

        def get
          @items
        end

        def id_
          field_values(:id_)
        end

        def name
          field_values(:name)
        end

        def completed
          field_values(:completed)
        end

        def modification_date
          field_values(:modification_date)
        end

        def tasks
          field_values(:tasks)
        end

        def method_missing(name, *args, &block)
          return super if args.any? || block

          field_values(name)
        end

        def respond_to_missing?(_name, _include_private = false)
          true
        end

        private

        def field_values(name)
          Value.new(@items.filter_map { |item| item.public_send(name).get if item.respond_to?(name) })
        end
      end

      class Reference
        attr_reader :data

        def initialize(data, transport: nil)
          @data = data || {}
          @transport = transport
        end

        def make(new:, with_properties:)
          Reference.new(
            @transport.create_item(kind: new, properties: with_properties, container: self),
            transport: @transport
          )
        end

        def get
          self
        end

        def id_
          property(:id_)
        end

        def name
          property(:name)
        end

        def completed
          property(:completed)
        end

        def note
          property(:note)
        end

        def modification_date
          property(:modification_date)
        end

        def tasks
          Collection.new(fetch_value(:tasks), transport: @transport)
        end

        def projects
          Lookup.new(fetch_value(:projects), transport: @transport)
        end

        def flattened_projects
          Lookup.new(flatten_projects(fetch_value(:projects)), transport: @transport)
        end

        def tags
          TagCollection.new(fetch_value(:tags), reference: self, transport: @transport)
        end

        def containing_project
          reference_from(:containing_project, :project)
        end

        def container
          reference_from(:container)
        end

        def assigned_container
          AssignedContainer.new(@transport, self)
        end

        def properties_
          Value.new(@data)
        end

        def mark_complete
          @transport&.complete_item(external_id)
        end

        def external_id
          fetch_value(:id_).to_s
        end

        def friendly_title
          name.get.to_s.strip
        end

        def method_missing(name, *args, &block)
          return super if args.any? || block

          return property(name) if @data.key?(name) || @data.key?(name.to_s) || @data.key?(name.to_sym)

          super
        end

        def respond_to_missing?(name, _include_private = false)
          @data.key?(name) || @data.key?(name.to_s) || @data.key?(name.to_sym) || super
        end

        private

        def property(name)
          Property.new(self, name, fetch_value(name), transport: @transport)
        end

        def reference_from(*keys)
          raw = keys.filter_map { |key| @data[key] || @data[key.to_s] || @data[key.to_sym] }.first
          raw.nil? ? Value.new(nil) : Reference.new(raw, transport: @transport)
        end

        def flatten_projects(projects)
          Array(projects).flat_map do |project|
            reference = project.is_a?(Reference) ? project : Reference.new(project, transport: @transport)
            [reference] + flatten_projects(reference.send(:fetch_value, :projects))
          end
        end

        def fetch_value(name)
          @data[name] || @data[name.to_s] || @data[name.to_sym]
        end

        def update_value(name, value)
          key = if @data.key?(name)
            name
          elsif @data.key?(name.to_s)
            name.to_s
          else
            name.to_sym
          end
          @data[key] = value
        end

        class Property
          def initialize(reference, name, value, transport:)
            @reference = reference
            @name = name
            @value = value
            @transport = transport
          end

          def get
            @value
          end

          def set(value)
            @transport&.update_item(reference: @reference, attributes: { @name => value })
            @reference.send(:update_value, @name, value)
            @value = value
          end
        end
      end

      class AssignedContainer
        def initialize(transport, reference)
          @transport = transport
          @reference = reference
        end

        def set(value)
          @transport&.move_task(reference: @reference, destination: value)
        end
      end

      class TagCollection < Collection
        attr_reader :reference

        def initialize(items, reference:, transport:)
          @reference = reference
          @transport = transport
          super(items)
        end
      end

      class Value
        def initialize(value)
          @value = value
        end

        def get
          @value
        end
      end

      class Transport
        SYNC_WEBSOCKET_ENDPOINT = {
          host: "sync.omnifocus.com",
          port: 443,
          path: "/socket"
        }.freeze
        WEB_WEBSOCKET_ENDPOINT = {
          host: "web.omnifocus.com",
          port: 443,
          path: "/socket"
        }.freeze
        ALLOWED_WEBSOCKET_ENDPOINTS = [
          SYNC_WEBSOCKET_ENDPOINT,
          WEB_WEBSOCKET_ENDPOINT
        ].freeze
        BLOCKED_WEBSOCKET_NETWORKS = %w[
          0.0.0.0/8
          10.0.0.0/8
          100.64.0.0/10
          127.0.0.0/8
          169.254.0.0/16
          172.16.0.0/12
          192.168.0.0/16
          224.0.0.0/4
          ::/128
          ::1/128
          fc00::/7
          fe80::/10
          ff00::/8
        ].map { |cidr| IPAddr.new(cidr) }.freeze
        SOCKET_PROTOCOL = "v1.omnifocus.omnigroup.com"
        SUPPORTED_LOCALES = %w[de en es fr it ja ko nl pt-BR ru zh].freeze
        WEB_CLIENT_VERSION = "*"

        attr_reader :account, :password, :server_label, :locale

        def initialize(account:, password:, server_label: nil, locale: nil)
          @account = account
          @password = password
          @server_label = server_label
          @locale = locale
          @response_cache = {}
          @session_key = nil
          @websocket_endpoint = nil
        end

        def load_collection(container:)
          fetch_collection(container:)
        end

        def load_lookup(container:)
          fetch_collection(container:)
        end

        def create_item(kind:, properties:, container: nil)
          operation, payload = create_request_for(kind:, properties:, container:)
          request(operation, payload:)
        end

        def add_tag(tag:, to:)
          request("edit", payload: { oid: external_id_for(to), tags: [external_id_for(tag)] })
        end

        def update_item(reference:, attributes:)
          request("edit", payload: { oid: external_id_for(reference), **attributes })
        end

        def complete_item(external_id)
          request("complete", payload: { ids: [external_id], done: true })
        end

        def move_task(reference:, destination:)
          request("move", payload: { ids: [external_id_for(reference)], in: external_id_for(destination), rel: "task" })
        end

        private

        def fetch_collection(container:)
          response = request("watch", payload: { in: container, view: "all" })
          Array(response["items"] || response["data"] || response["results"])
        end

        def request(operation, payload:)
          socket = websocket
          request_id = SecureRandom.uuid
          socket.send_json({ op: operation, rid: request_id, **payload })

          loop do
            response = parse_response(socket.receive_json)
            next if response.blank?

            if authentication_message?(response)
              handle_authentication_message!(socket, response)
              next
            end

            return response if response["rid"] == request_id || response["request_id"] == request_id
          end
        end

        def websocket
          @websocket ||= SocketConnection.new(websocket_endpoint, protocols: [SOCKET_PROTOCOL]).tap do |socket|
            authenticate_socket!(socket)
          end
        end

        def websocket_endpoint
          @websocket_endpoint ||= build_websocket_endpoint(resolve_instance.fetch("ws_url"))
        end

        def resolve_instance
          @response_cache[:instance] ||= begin
            uri = URI("https://c.omnifocus.com/api/0/get-instance")
            uri.query = URI.encode_www_form(
              account:,
              server: server_label,
              version: WEB_CLIENT_VERSION,
              locale: normalized_locale,
              timezone: Time.now.getlocal.zone
            )
            response = Net::HTTP.get_response(uri)
            parsed = JSON.parse(response.body)
            raise AuthenticationError, parsed["error"] || parsed["message"] if parsed["ws_url"].blank?

            parsed
          end
        end

        def create_request_for(kind:, properties:, container:)
          operation = kind.to_s
          payload = properties.dup

          if operation == "inbox_task"
            operation = "task"
            payload[:in] = "inbox"
          end

          payload[:in] = external_id_for(container) if container
          [operation, payload]
        end

        def authenticate_socket!(socket)
          loop do
            response = parse_response(socket.receive_json)
            next if response.blank?

            handle_authentication_message!(socket, response)
            return socket if response["op"] == "session"
          end
        end

        def authentication_message?(response)
          %w[cookie error key? pw? session state version].include?(response["op"])
        end

        def build_websocket_endpoint(url)
          uri = URI.parse(url)
          raise ConnectionError, "OmniFocus Web websocket URL must use wss" unless uri.scheme == "wss"
          raise ConnectionError, "OmniFocus Web websocket URL must include a host" if uri.host.blank?
          raise ConnectionError, "OmniFocus Web websocket URL must not include credentials" if uri.userinfo.present?
          raise ConnectionError, "OmniFocus Web websocket URL must not include query parameters" if uri.query.present?
          raise ConnectionError, "OmniFocus Web websocket URL must not include a fragment" if uri.fragment.present?

          endpoint = canonical_websocket_endpoint(uri)
          raise ConnectionError, "OmniFocus Web websocket URL is not allowed" if endpoint.nil?

          resolved_address = validated_public_websocket_address(endpoint.fetch(:host))
          raise ConnectionError, "OmniFocus Web websocket URL host is not allowed" if resolved_address.nil?

          WebsocketEndpoint.new(**endpoint.slice(:host, :port, :path), connect_host: resolved_address)
        rescue URI::InvalidURIError => e
          raise ConnectionError, "Invalid OmniFocus Web websocket URL: #{e.message}"
        end

        def canonical_websocket_endpoint(uri)
          case [
            normalized_websocket_host(uri.host),
            normalized_websocket_port(uri.port),
            normalized_websocket_path(uri.path)
          ]
          when [SYNC_WEBSOCKET_ENDPOINT.fetch(:host), SYNC_WEBSOCKET_ENDPOINT.fetch(:port), SYNC_WEBSOCKET_ENDPOINT.fetch(:path)]
            SYNC_WEBSOCKET_ENDPOINT
          when [WEB_WEBSOCKET_ENDPOINT.fetch(:host), WEB_WEBSOCKET_ENDPOINT.fetch(:port), WEB_WEBSOCKET_ENDPOINT.fetch(:path)]
            WEB_WEBSOCKET_ENDPOINT
          end
        end

        def normalized_websocket_host(host)
          normalized_host = host.to_s.strip.downcase
          raise ConnectionError, "OmniFocus Web websocket URL must include a host" if normalized_host.blank?
          raise ConnectionError, "OmniFocus Web websocket URL host is not allowed" unless normalized_host.ascii_only?
          raise ConnectionError, "OmniFocus Web websocket URL host is not allowed" if ip_literal?(normalized_host)

          normalized_host
        end

        def normalized_websocket_port(port)
          raise ConnectionError, "OmniFocus Web websocket URL port is not allowed" unless port.nil? || port == 443

          443
        end

        def ip_literal?(host)
          IPAddr.new(host)
          true
        rescue IPAddr::InvalidAddressError
          false
        end

        def validated_public_websocket_address(host)
          addresses = resolved_ip_addresses(host)
          return if addresses.empty?
          return unless addresses.all? { |address| public_ip_address?(address) }

          addresses.first
        rescue SocketError
          nil
        end

        def resolved_ip_addresses(host)
          Addrinfo.getaddrinfo(host, 443, nil, :STREAM).filter_map(&:ip_address).uniq
        end

        def public_ip_address?(address)
          ip_address = IPAddr.new(address)
          BLOCKED_WEBSOCKET_NETWORKS.none? { |network| network.include?(ip_address) }
        rescue IPAddr::InvalidAddressError
          false
        end

        def normalized_websocket_path(path)
          normalized_path = path.to_s
          normalized_path = "/#{normalized_path}" unless normalized_path.start_with?("/")
          normalized_path = normalized_path.presence || "/"
          raise ConnectionError, "OmniFocus Web websocket URL path is not allowed" unless normalized_path.match?(%r{\A/[A-Za-z0-9\-._~/]*\z})

          normalized_path
        end

        def handle_authentication_message!(socket, response)
          case response["op"]
          when "pw?"
            socket.send_json(op: "pw", rid: SecureRandom.uuid, kind: response["kind"], value: password)
          when "key?"
            raise AuthenticationError, "Encrypted OmniFocus Web databases require an encryption key, which this backend does not support"
          when "error"
            raise AuthenticationError, response["message"] || response["reason"] || "OmniFocus Web authentication failed"
          when "session"
            @session_key = response["key"]
          end
        end

        def normalized_locale
          return locale if SUPPORTED_LOCALES.include?(locale)

          "en-US"
        end

        def external_id_for(reference)
          return reference.reference.external_id if reference.respond_to?(:reference) && reference.reference.respond_to?(:external_id)
          return reference.external_id if reference.respond_to?(:external_id)
          return reference.get.external_id if reference.respond_to?(:get) && reference.get.respond_to?(:external_id)

          reference.to_s
        end

        def parse_response(response)
          return {} if response.blank?

          JSON.parse(response)
        rescue JSON::ParserError
          {}
        end

        class WebsocketEndpoint
          attr_reader :connect_host, :host, :path, :port

          def initialize(host:, port:, path:, connect_host:)
            @connect_host = connect_host
            @host = host
            @port = port
            @path = path
          end

          def uri
            URI::Generic.build(
              scheme: "wss",
              host:,
              port:,
              path:
            )
          end
        end
      end

      class SocketConnection
        def initialize(endpoint, protocols: [])
          @endpoint = endpoint
          @handshake = WebSocket::Handshake::Client.new(url: @endpoint.uri.to_s, protocols:)
          @socket = connect_socket
          @socket.write(@handshake.to_s)
          finish_handshake!
          @incoming = WebSocket::Frame::Incoming::Client.new(version: @handshake.version)
        end

        def send_json(payload)
          frame = WebSocket::Frame::Outgoing::Client.new(version: @handshake.version, data: payload.to_json, type: :text)
          @socket.write(frame.to_s)
        end

        def receive_json
          loop do
            buffer = @socket.readpartial(4096)
            @incoming << buffer
            if (message = @incoming.next)
              return message.to_s
            end
          end
        end

        private

        def connect_socket
          tcp_socket = TCPSocket.new(@endpoint.connect_host, @endpoint.port)
          ssl_socket = OpenSSL::SSL::SSLSocket.new(tcp_socket, ssl_context)
          ssl_socket.sync_close = true
          ssl_socket.hostname = @endpoint.host if ssl_socket.respond_to?(:hostname=)
          ssl_socket.connect
          ssl_socket.post_connection_check(@endpoint.host)
          ssl_socket
        end

        def finish_handshake!
          loop do
            break if @handshake.finished?

            @handshake << @socket.readpartial(4096)
          end
          raise AuthenticationError, "WebSocket handshake failed" unless @handshake.valid?
        end

        def ssl_context
          @ssl_context ||= OpenSSL::SSL::SSLContext.new.tap do |context|
            context.verify_mode = OpenSSL::SSL::VERIFY_PEER
            context.verify_hostname = true if context.respond_to?(:verify_hostname=)
          end
        end
      end
    end
  end
end
