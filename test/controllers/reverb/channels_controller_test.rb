require "test_helper"

class Reverb::ChannelsControllerTest < ActionDispatch::IntegrationTest
  KEY    = "test-app-key"
  SECRET = "test-app-secret"

  setup do
    @room = rooms(:designers)
    # Every human fixture belongs to :designers, so :pets is the room the
    # signed-in user is a stranger to.
    @other_room = rooms(:pets)
    ReverbClient.stubs(:instance).returns(
      ReverbClient.new(app_id: "1", key: KEY, secret: SECRET, host: "reverb.test", port: "443", scheme: "https")
    )
    sign_in :kevin
  end

  # --- resolve -------------------------------------------------------------

  test "a signed Turbo stream name resolves to its Pusher channel" do
    signed = Turbo::StreamsChannel.signed_stream_name [ @room, :messages ]

    post reverb_subscription_url, params: { channel: "RoomMessagesChannel", signed_stream_name: signed }, as: :json

    assert_response :success
    assert_equal ReverbStream.channel_for("#{@room.to_gid_param}:messages"), response.parsed_body["channel"]
  end

  test "a forged Turbo stream name resolves to nothing" do
    post reverb_subscription_url, params: { channel: "RoomMessagesChannel", signed_stream_name: "made-up" }, as: :json

    assert_response :forbidden
  end

  test "per-user streams are resolved from the session, never from the request" do
    post reverb_subscription_url, params: { channel: "UnreadRoomsChannel", user_id: users(:david).id }, as: :json

    assert_response :success
    assert_equal ReverbStream.channel_for("user_#{users(:kevin).id}_unreads"), response.parsed_body["channel"]
  end

  test "a room channel resolves through the channel class itself" do
    post reverb_subscription_url, params: { channel: "PresenceChannel", room_id: @room.id }, as: :json

    assert_response :success
    assert_equal ReverbStream.channel_for(PresenceChannel.broadcasting_for(@room)), response.parsed_body["channel"]
    assert_equal "present", response.parsed_body["on_subscribe"]
    assert_equal "absent", response.parsed_body["on_unsubscribe"]
  end

  test "a room the user is not a member of does not resolve" do
    post reverb_subscription_url, params: { channel: "PresenceChannel", room_id: rooms(:bender_and_kevin).id }, as: :json
    assert_response :success # kevin is a member of this one

    post reverb_subscription_url, params: { channel: "PresenceChannel", room_id: @other_room.id }, as: :json
    assert_response :forbidden
  end

  test "the heartbeat channel resolves to no channel at all" do
    post reverb_subscription_url, params: { channel: "HeartbeatChannel" }, as: :json

    assert_response :success
    assert_nil response.parsed_body["channel"]
  end

  test "a channel the app does not use cannot be named" do
    post reverb_subscription_url, params: { channel: "ApplicationCable::Channel" }, as: :json
    assert_response :forbidden

    post reverb_subscription_url, params: { channel: "Kernel" }, as: :json
    assert_response :forbidden
  end

  test "resolving requires a session" do
    delete session_url

    post reverb_subscription_url, params: { channel: "HeartbeatChannel" }, as: :json

    assert_redirected_to new_session_url
  end

  # --- authenticate --------------------------------------------------------

  test "a member's subscription is signed with the Pusher formula" do
    channel = ReverbStream.channel_for("#{@room.to_gid_param}:messages")

    post reverb_auth_url, params: { socket_id: "123.456", channel_name: channel }, as: :json

    assert_response :success
    expected = OpenSSL::HMAC.hexdigest("sha256", SECRET, "123.456:#{channel}")
    assert_equal "#{KEY}:#{expected}", response.parsed_body["auth"]
  end

  test "a non-member is refused a signature for a room's message stream" do
    channel = ReverbStream.channel_for("#{@other_room.to_gid_param}:messages")

    post reverb_auth_url, params: { socket_id: "123.456", channel_name: channel }, as: :json

    assert_response :forbidden
    assert_empty response.body
  end

  test "a revoked member is refused a signature for a stream they used to read" do
    channel = ReverbStream.channel_for("#{@room.to_gid_param}:messages")
    post reverb_auth_url, params: { socket_id: "1.1", channel_name: channel }, as: :json
    assert_response :success

    @room.memberships.find_by(user: users(:kevin)).destroy!

    post reverb_auth_url, params: { socket_id: "1.1", channel_name: channel }, as: :json
    assert_response :forbidden
  end

  test "another user's private streams are refused" do
    [ "user_#{users(:david).id}_reads", "user_#{users(:david).id}_unreads", "#{users(:david).to_gid_param}:rooms" ].each do |stream|
      post reverb_auth_url, params: { socket_id: "1.1", channel_name: ReverbStream.channel_for(stream) }, as: :json

      assert_response :forbidden, stream
    end
  end

  test "a channel name outside our encoding is refused" do
    [ "private-anything", "presence-rooms", "private-ac-", "private-ac-!!" ].each do |channel|
      post reverb_auth_url, params: { socket_id: "1.1", channel_name: channel }, as: :json

      assert_response :forbidden, channel
    end
  end

  test "a signature needs a socket id" do
    post reverb_auth_url, params: { channel_name: ReverbStream.channel_for("rooms") }, as: :json

    assert_response :forbidden
  end

  test "authenticating requires a session" do
    delete session_url

    post reverb_auth_url, params: { socket_id: "1.1", channel_name: ReverbStream.channel_for("rooms") }, as: :json

    assert_redirected_to new_session_url
  end

  # --- perform -------------------------------------------------------------

  test "a typing notification is broadcast to the room's typing stream" do
    assert_broadcast_on TypingNotificationsChannel.broadcasting_for(@room),
      action: "start", user: { id: users(:kevin).id, name: users(:kevin).name } do
      post reverb_perform_url, params: { channel: "TypingNotificationsChannel", room_id: @room.id, channel_action: "start" }, as: :json
    end

    assert_response :no_content
  end

  test "a non-member cannot make the room think they are typing" do
    assert_no_broadcasts TypingNotificationsChannel.broadcasting_for(@other_room) do
      post reverb_perform_url, params: { channel: "TypingNotificationsChannel", room_id: @other_room.id, channel_action: "start" }, as: :json
    end

    assert_response :forbidden
  end

  test "presence marks the membership connected and tells the user's own read stream" do
    membership = @room.memberships.find_by(user: users(:kevin))
    membership.update! connected_at: nil, connections: 0

    assert_broadcast_on "user_#{users(:kevin).id}_reads", room_id: @room.id do
      post reverb_perform_url, params: { channel: "PresenceChannel", room_id: @room.id, channel_action: "present" }, as: :json
    end

    assert_response :no_content
    assert membership.reload.connected?
  end

  test "absence disconnects the membership" do
    membership = @room.memberships.find_by(user: users(:kevin))
    membership.present

    post reverb_perform_url, params: { channel: "PresenceChannel", room_id: @room.id, channel_action: "absent" }, as: :json

    assert_response :no_content
    assert_not membership.reload.connected?
  end

  test "refresh keeps a present membership present" do
    membership = @room.memberships.find_by(user: users(:kevin))
    membership.present
    membership.update_columns connected_at: 40.seconds.ago

    post reverb_perform_url, params: { channel: "PresenceChannel", room_id: @room.id, channel_action: "refresh" }, as: :json

    assert_response :no_content
    assert membership.reload.connected_at > 5.seconds.ago
  end

  test "only the channel messages Campfire actually sends are performable" do
    [ [ "PresenceChannel", "start" ], [ "TypingNotificationsChannel", "present" ],
      [ "ReadRoomsChannel", "read" ], [ "PresenceChannel", nil ] ].each do |channel, action|
      post reverb_perform_url, params: { channel: channel, room_id: @room.id, channel_action: action }, as: :json

      assert_response :forbidden, "#{channel}##{action}"
    end
  end
end
