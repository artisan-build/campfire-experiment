require "test_helper"
require "action_cable/subscription_adapter/reverb"

class ActionCable::SubscriptionAdapter::ReverbTest < ActiveSupport::TestCase
  # Records what would have gone to Reverb's HTTP API.
  class RecordingClient
    attr_reader :triggers

    def initialize(error: nil)
      @triggers, @error = [], error
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
