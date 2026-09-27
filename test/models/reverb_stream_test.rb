require "test_helper"

class ReverbStreamTest < ActiveSupport::TestCase
  test "a channel name round-trips back to its stream name" do
    [ "user_42_unreads", "rooms", "Z2lkOi8vY2FtcGZpcmUvUm9vbS8z:messages", "presence:Z2lkOi8v" ].each do |stream_name|
      channel = ReverbStream.channel_for(stream_name)

      assert_equal stream_name, ReverbStream.stream_for(channel)
    end
  end

  test "channel names stay inside Pusher's legal character set and private prefix" do
    channel = ReverbStream.channel_for("gid://campfire/Room/3:messages+/=")

    assert channel.start_with?("private-")
    assert_match(/\Aprivate-ac-[A-Za-z0-9\-_]+\z/, channel)
  end

  test "a name that is not one of ours decodes to nothing" do
    assert_nil ReverbStream.stream_for("private-something-else")
    assert_nil ReverbStream.stream_for("presence-rooms")
    assert_nil ReverbStream.stream_for("private-ac-")
    assert_nil ReverbStream.stream_for(nil)
  end

  test "undecodable payloads decode to nothing rather than raising" do
    assert_nil ReverbStream.stream_for("private-ac-!!!not base64!!!")
  end

  test "too_long? is measured against Pusher's channel name limit" do
    assert_not ReverbStream.too_long?(ReverbStream.channel_for("user_1_reads"))
    assert ReverbStream.too_long?(ReverbStream.channel_for("x" * ReverbStream::MAX_LENGTH))
  end
end
