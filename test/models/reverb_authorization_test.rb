require "test_helper"

class ReverbAuthorizationTest < ActiveSupport::TestCase
  setup do
    @member     = users(:kevin)
    @non_member = users(:bender)
    @room       = rooms(:designers)
  end

  test "a member may read a room's turbo message stream" do
    assert authorized?(@member, "#{@room.to_gid_param}:messages")
  end

  test "a non-member may not read a room's turbo message stream" do
    assert_not authorized?(@non_member, "#{@room.to_gid_param}:messages")
  end

  test "a member may read the per-room channels, a non-member may not" do
    %w[ room presence typing_notifications ].each do |channel|
      assert authorized?(@member, "#{channel}:#{@room.to_gid_param}"), channel
      assert_not authorized?(@non_member, "#{channel}:#{@room.to_gid_param}"), channel
    end
  end

  test "revoking a membership revokes the stream" do
    assert authorized?(@member, "#{@room.to_gid_param}:messages")

    @room.memberships.find_by(user: @member).destroy!

    assert_not authorized?(@member.reload, "#{@room.to_gid_param}:messages")
  end

  test "a user's own read and unread streams are theirs alone" do
    assert authorized?(@member, "user_#{@member.id}_reads")
    assert authorized?(@member, "user_#{@member.id}_unreads")
    assert_not authorized?(@member, "user_#{@non_member.id}_reads")
    assert_not authorized?(@member, "user_#{@non_member.id}_unreads")
  end

  test "another user's sidebar room stream is refused" do
    assert authorized?(@member, "#{@member.to_gid_param}:rooms")
    assert_not authorized?(@member, "#{@non_member.to_gid_param}:rooms")
  end

  test "the account-wide room list is open to any signed-in user" do
    assert authorized?(@non_member, "rooms")
  end

  test "unrecognised streams are refused" do
    [ "", "  ", "anything", "user_x_reads", "rooms:extra", "#{@room.to_gid_param}:whatever",
      "#{@room.to_gid_param}", "boosts:#{@room.to_gid_param}", "presence:not-a-gid" ].each do |stream_name|
      assert_not authorized?(@member, stream_name), stream_name.inspect
    end
  end

  test "a stream for a room that no longer exists is refused" do
    gid_param = @room.to_gid_param
    @room.destroy!

    assert_not authorized?(@member, "#{gid_param}:messages")
  end

  test "nobody is nobody" do
    assert_not authorized?(nil, "rooms")
  end

  private
    def authorized?(user, stream_name)
      ReverbAuthorization.new(user).authorized?(stream_name)
    end
end
