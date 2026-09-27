# The server half of the browser's Pusher transport.
#
#   resolve       names the Pusher channel behind an Action Cable subscription,
#                 so all channel-name knowledge stays in Ruby;
#   authenticate  signs that subscription — the authorization gate Reverb makes
#                 the browser pass before it joins a private channel;
#   perform       carries client-to-server channel messages (typing, presence),
#                 which the Pusher protocol would otherwise need client events
#                 for.
#
# Session authentication and banned-request blocking come from
# ApplicationController, so these endpoints are exactly as authenticated as the
# rest of Campfire.
class Reverb::ChannelsController < ApplicationController
  # Which Action Cable channels a browser may name, how each one's stream is
  # derived, and the lifecycle messages Action Cable's own on_subscribe /
  # on_unsubscribe callbacks would have sent for it.
  CHANNELS = {
    "Turbo::StreamsChannel"      => { stream: :signed_stream },
    "RoomMessagesChannel"        => { stream: :signed_stream },
    "ReadRoomsChannel"           => { stream: :reads_stream },
    "UnreadRoomsChannel"         => { stream: :unreads_stream },
    "RoomChannel"                => { stream: :room_stream },
    "TypingNotificationsChannel" => { stream: :room_stream },
    "PresenceChannel"            => { stream: :room_stream, on_subscribe: "present", on_unsubscribe: "absent" },
    # No stream of its own: the socket being up IS the heartbeat.
    "HeartbeatChannel"           => { stream: :no_stream }
  }.freeze

  # Channel messages a browser may send, per channel.
  PERFORMABLE = {
    "TypingNotificationsChannel" => %w[ start stop ],
    "PresenceChannel"            => %w[ present absent refresh ]
  }.freeze

  def resolve
    return head :forbidden unless channel = CHANNELS[params[:channel]]

    if channel[:stream] == :no_stream
      render json: { channel: nil }
    elsif stream_name = send(channel[:stream])
      render json: {
        channel: ReverbStream.channel_for(stream_name),
        on_subscribe: channel[:on_subscribe],
        on_unsubscribe: channel[:on_unsubscribe]
      }
    else
      head :forbidden
    end
  end

  def authenticate
    stream_name = ReverbStream.stream_for(params[:channel_name])

    if params[:socket_id].present? && stream_name && ReverbAuthorization.new(Current.user).authorized?(stream_name)
      render json: { auth: ReverbClient.instance.subscription_auth(socket_id: params[:socket_id], channel: params[:channel_name]) }
    else
      head :forbidden
    end
  end

  def perform
    return head :forbidden unless PERFORMABLE[params[:channel]]&.include?(params[:channel_action])
    return head :forbidden unless room = Current.user.rooms.find_by(id: params[:room_id])

    case params[:channel]
    when "TypingNotificationsChannel" then typing_notification room
    when "PresenceChannel"            then presence room
    end

    head :no_content
  end

  private
    # Turbo signs its stream names; verifying the signature is what turns the
    # client's claim back into a stream name we will look at.
    def signed_stream
      Turbo.signed_stream_verifier.verified(params[:signed_stream_name]).presence
    end

    def reads_stream
      "user_#{Current.user.id}_reads"
    end

    def unreads_stream
      UnreadRoomsChannel.stream_name_for Current.user.id
    end

    # Asks the channel class itself for the name, so the mapping cannot drift
    # from what ActionCable::Channel#stream_for would have produced.
    def room_stream
      room = Current.user.rooms.find_by(id: params[:room_id])
      params[:channel].constantize.broadcasting_for(room) if room
    end

    def typing_notification(room)
      TypingNotificationsChannel.broadcast_to room,
        action: params[:channel_action], user: Current.user.slice(:id, :name)
    end

    # Mirrors PresenceChannel's callbacks, including the read-room broadcast it
    # sends when a member arrives.
    def presence(room)
      membership = room.memberships.find_by(user: Current.user)
      return unless membership

      case params[:channel_action]
      when "present"
        membership.present
        ActionCable.server.broadcast "user_#{Current.user.id}_reads", { room_id: membership.room_id }
      when "absent"  then membership.disconnected
      when "refresh" then membership.refresh_connection
      end
    end
end
