require "test_helper"
require "action_cable/subscription_adapter/reverb"

class ActionCable::SubscriptionAdapter::ReverbTest < ActiveSupport::TestCase
  # Records what would have gone to Reverb's HTTP API.
  class RecordingClient
    attr_reader :triggers

    attr_reader :max_message_size

    def initialize(error: nil, max_message_size: ReverbClient::DEFAULT_MAX_MESSAGE_SIZE)
      @triggers, @error, @max_message_size = [], error, max_message_size
    end

    def trigger(channel:, event:, data:)
      @triggers << { channel: channel, event: event, data: data }
      raise @error if @error
    end
  end

  setup do
    @client = RecordingClient.new
    ReverbClient.stubs(:instance).returns(@client)

    @adapter = ActionCable::SubscriptionAdapter::Reverb.new(ActionCable.server)
    @original_pubsub = ActionCable.server.pubsub
    ActionCable.server.instance_variable_set :@pubsub, @adapter
  end

  teardown do
    ActionCable.server.instance_variable_set :@pubsub, @original_pubsub
  end

  test "a broadcast is published to the stream's Pusher channel with the payload untouched" do
    payload = ActiveSupport::JSON.encode("<turbo-stream action=\"append\"></turbo-stream>")

    @adapter.broadcast "Z2lk:messages", payload

    assert_equal [ { channel: ReverbStream.channel_for("Z2lk:messages"), event: "action_cable", data: payload } ],
      @client.triggers
  end

  test "a Turbo Stream broadcast reaches Reverb without any call-site change" do
    Turbo::StreamsChannel.broadcast_remove_to :rooms, target: "room_1"

    assert_equal [ ReverbStream.channel_for("rooms") ], @client.triggers.map { |trigger| trigger[:channel] }
    assert_includes @client.triggers.sole[:data], "turbo-stream"
  end

  test "a direct ActionCable.server.broadcast reaches Reverb too" do
    ActionCable.server.broadcast UnreadRoomsChannel.stream_name_for(42), { roomId: 7 }

    assert_equal ReverbStream.channel_for("user_42_unreads"), @client.triggers.sole[:channel]
    assert_equal({ "roomId" => 7 }, JSON.parse(@client.triggers.sole[:data]))
  end

  test "a failed publish is logged, not raised, so the request that triggered it survives" do
    ReverbClient.stubs(:instance).returns(RecordingClient.new(error: ReverbClient::Error.new("503 unavailable")))

    assert_nothing_raised do
      @adapter.broadcast "user_1_reads", "{}"
    end
  end

  test "a payload over Reverb's message limit is deflated, and inflates back to the original" do
    payload = ActiveSupport::JSON.encode("<turbo-stream>#{"a message partial " * 800}</turbo-stream>")
    assert_operator payload.bytesize, :>, ReverbClient::DEFAULT_MAX_MESSAGE_SIZE

    @adapter.broadcast "Z2lk:messages", payload

    sent = JSON.parse(@client.triggers.sole[:data])
    assert_operator @client.triggers.sole[:data].bytesize, :<, ReverbClient::DEFAULT_MAX_MESSAGE_SIZE
    assert_equal payload,
      Zlib::Inflate.inflate(Base64.strict_decode64(sent[ActionCable::SubscriptionAdapter::Reverb::COMPRESSED_KEY]))
  end

  test "a payload inside the limit is sent as is, so the browser parses it like Action Cable's own" do
    payload = ActiveSupport::JSON.encode("<turbo-stream>small</turbo-stream>")

    @adapter.broadcast "Z2lk:messages", payload

    assert_equal payload, @client.triggers.sole[:data]
  end

  test "a stream whose channel name would exceed Pusher's limit is not published" do
    @adapter.broadcast "x" * ReverbStream::MAX_LENGTH, "{}"

    assert_empty @client.triggers
  end

  test "the subscribe half is inert: browsers talk to Reverb directly" do
    confirmed = false

    assert_nothing_raised do
      @adapter.subscribe "user_1_reads", ->(_message) {}, -> { confirmed = true }
      @adapter.unsubscribe "user_1_reads", ->(_message) {}
      @adapter.shutdown
    end

    assert confirmed
  end
end
