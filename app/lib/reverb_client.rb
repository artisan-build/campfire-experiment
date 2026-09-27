require "net/http"
require "openssl"
require "digest"

# Publishes events to a Pusher-protocol server — here Laravel Cloud's managed
# Reverb — and signs private-channel subscriptions for it.
#
# The Pusher HTTP API is four lines of HMAC over a sorted query string, so this
# does it by hand rather than adding the `pusher` gem. A fork whose whole point
# is measuring drift from upstream should not pay a Gemfile + Gemfile.lock
# conflict for forty lines of Net::HTTP.
class ReverbClient
  class Error < StandardError; end

  AUTH_VERSION = "1.0"
  DEFAULT_TIMEOUT = 5

  # Cloud creates WebSocket applications with a 10,000-byte max message size and
  # exposes no flag to change it; Reverb answers 413 above it.
  DEFAULT_MAX_MESSAGE_SIZE = 10_000

  # Cloud fronts the Reverb host with Cloudflare, whose browser integrity check
  # answers a default Net::HTTP user agent with a Cloudflare 403 (error 1010)
  # before Reverb ever sees the request. Verified live: the same signed POST
  # fails as "Ruby" and succeeds as a browser.
  USER_AGENT = "Mozilla/5.0 (compatible; Campfire/1.0; +Reverb)"

  class << self
    # True when a WebSocket application is attached: Cloud injects all five
    # names below. Nothing in this file is reachable otherwise, which is what
    # keeps development, test and CI on Action Cable's own WebSocket.
    def configured?
      %w[ REVERB_APP_ID REVERB_APP_KEY REVERB_APP_SECRET REVERB_HOST ].all? { |name| ENV[name].present? }
    end

    def instance
      @instance ||= new
    end

    # Test seam: the memoized client caches the environment it was built from.
    def reset!
      @instance = nil
    end
  end

  attr_reader :app_id, :key, :host, :port, :scheme, :max_message_size

  def initialize(app_id: ENV["REVERB_APP_ID"], key: ENV["REVERB_APP_KEY"], secret: ENV["REVERB_APP_SECRET"],
                 host: ENV["REVERB_HOST"], port: ENV["REVERB_PORT"], scheme: ENV["REVERB_SCHEME"],
                 timeout: DEFAULT_TIMEOUT, max_message_size: ENV["REVERB_MAX_MESSAGE_SIZE"])
    @app_id, @key, @secret, @host = app_id, key, secret, host
    @scheme = scheme.presence || "https"
    @port = (port.presence || (@scheme == "https" ? 443 : 80)).to_i
    @timeout = timeout
    @max_message_size = (max_message_size.presence || DEFAULT_MAX_MESSAGE_SIZE).to_i
  end

  # What the browser needs to open its own socket. Never the secret.
  def client_config
    # cluster is inert once host is set, but pusher-js refuses to start without it.
    { key: key, host: host, port: port, scheme: scheme, forceTLS: scheme == "https", cluster: "reverb" }
  end

  # `data` is passed through verbatim when it is already a string, so an
  # Action Cable payload (which arrives JSON-encoded) is not re-encoded: the
  # browser then parses exactly the value Action Cable's own client would have.
  def trigger(channel:, event:, data:)
    body = JSON.generate(name: event, channel: channel, data: data.is_a?(String) ? data : JSON.generate(data))
    post "/apps/#{app_id}/events", body
  end

  # Pusher's private/presence channel signature.
  def subscription_auth(socket_id:, channel:)
    "#{key}:#{signature("#{socket_id}:#{channel}")}"
  end

  private
    attr_reader :secret, :timeout

    def post(path, body)
      uri = URI("#{scheme}://#{host}:#{port}#{path}?#{signed_query("POST", path, body)}")

      response = http(uri).post("#{uri.path}?#{uri.query}", body,
        "Content-Type" => "application/json", "User-Agent" => USER_AGENT)
      raise Error, "#{response.code} #{response.body.to_s.truncate(200)}" unless response.is_a?(Net::HTTPSuccess)

      response
    rescue Error
      raise
    rescue StandardError => e
      raise Error, "#{e.class}: #{e.message}"
    end

    def http(uri)
      Net::HTTP.new(uri.host, uri.port).tap do |http|
        # Certificates are always verified: Cloud's Reverb host has a real one,
        # and a local Reverb without one should be reached over REVERB_SCHEME=http
        # rather than by turning verification off.
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = http.read_timeout = http.write_timeout = timeout
      end
    end

    # Pusher signs "METHOD\npath\nalphabetically-sorted-query".
    def signed_query(method, path, body)
      params = {
        "auth_key" => key,
        "auth_timestamp" => Time.now.to_i.to_s,
        "auth_version" => AUTH_VERSION,
        "body_md5" => Digest::MD5.hexdigest(body)
      }

      params["auth_signature"] = signature [ method, path, query_string(params.sort) ].join("\n")
      query_string(params)
    end

    def query_string(pairs)
      pairs.map { |key, value| "#{key}=#{value}" }.join("&")
    end

    def signature(payload)
      OpenSSL::HMAC.hexdigest "sha256", secret, payload
    end
end
