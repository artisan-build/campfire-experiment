require "test_helper"

class ReverbClientTest < ActiveSupport::TestCase
  APP_ID = "10002"
  KEY    = "test-app-key"
  SECRET = "test-app-secret"
  HOST   = "ws-test-reverb.laravel.cloud"

  setup do
    @client = ReverbClient.new(app_id: APP_ID, key: KEY, secret: SECRET, host: HOST, port: "443", scheme: "https")
  end

  test "configured? needs every injected name" do
    assert_not ReverbClient.configured?

    with_env("REVERB_APP_ID" => APP_ID, "REVERB_APP_KEY" => KEY, "REVERB_APP_SECRET" => SECRET) do
      assert_not ReverbClient.configured?, "missing REVERB_HOST should not count as configured"

      with_env("REVERB_HOST" => HOST) { assert ReverbClient.configured? }
    end
  end

  test "the browser's config never carries the secret" do
    config = @client.client_config

    assert_equal KEY, config[:key]
    assert_equal HOST, config[:host]
    assert_equal 443, config[:port]
    assert config[:forceTLS]
    assert_not_includes config.to_json, SECRET
  end

  test "an event is posted to the Pusher events endpoint, signed" do
    request = stub_request(:post, %r{\Ahttps://#{HOST}/apps/#{APP_ID}/events}).to_return(status: 200, body: "{}")

    @client.trigger channel: "private-ac-abc", event: "action_cable", data: %({"a":1})

    assert_requested request do |sent|
      body = JSON.parse(sent.body)
      query = Rack::Utils.parse_query(sent.uri.query)

      assert_equal "private-ac-abc", body["channel"]
      assert_equal "action_cable", body["name"]
      assert_equal %({"a":1}), body["data"], "a string payload must pass through unencoded"

      assert_equal KEY, query["auth_key"]
      assert_equal "1.0", query["auth_version"]
      assert_equal Digest::MD5.hexdigest(sent.body), query["body_md5"]
      assert_equal expected_signature(query, sent.body), query["auth_signature"]
    end
  end

  test "a non-string payload is JSON encoded" do
    stub_request(:post, %r{/apps/#{APP_ID}/events}).to_return(status: 200, body: "{}")

    @client.trigger channel: "private-ac-abc", event: "action_cable", data: { room_id: 3 }

    assert_requested :post, %r{/apps/#{APP_ID}/events} do |sent|
      assert_equal %({"room_id":3}), JSON.parse(sent.body)["data"]
    end
  end

  test "a rejected publish raises ReverbClient::Error carrying the status" do
    stub_request(:post, %r{/apps/#{APP_ID}/events}).to_return(status: 413, body: "payload too large")

    error = assert_raises ReverbClient::Error do
      @client.trigger channel: "private-ac-abc", event: "action_cable", data: "{}"
    end

    assert_match "413", error.message
  end

  test "a connection failure raises ReverbClient::Error, not a bare network error" do
    stub_request(:post, %r{/apps/#{APP_ID}/events}).to_timeout

    assert_raises ReverbClient::Error do
      @client.trigger channel: "private-ac-abc", event: "action_cable", data: "{}"
    end
  end

  test "a subscription is signed the way Pusher specifies" do
    expected = OpenSSL::HMAC.hexdigest("sha256", SECRET, "123.456:private-ac-abc")

    assert_equal "#{KEY}:#{expected}", @client.subscription_auth(socket_id: "123.456", channel: "private-ac-abc")
  end

  private
    def expected_signature(query, body)
      signed = query.slice("auth_key", "auth_timestamp", "auth_version", "body_md5")
        .sort.map { |key, value| "#{key}=#{value}" }.join("&")

      OpenSSL::HMAC.hexdigest "sha256", SECRET, [ "POST", "/apps/#{APP_ID}/events", signed ].join("\n")
    end

    def with_env(values)
      original = values.keys.index_with { |key| ENV[key] }
      values.each { |key, value| ENV[key] = value }
      yield
    ensure
      original.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    end
end
