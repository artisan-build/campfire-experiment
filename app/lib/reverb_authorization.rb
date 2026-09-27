# Decides whether a user may subscribe to an Action Cable stream.
#
# This is the gate. Reverb asks POST /reverb/auth to sign every private channel
# a browser subscribes to, and the channel name decodes back to the stream name
# (see ReverbStream), so no subscription reaches a stream without passing
# through here — whatever channel the client names.
#
# Default is deny: a stream shape this class does not recognise is refused
# rather than signed.
class ReverbAuthorization
  # Streams any signed-in user may read. :rooms carries the account-wide room
  # list, which is what upstream already broadcasts open-room changes on.
  ACCOUNT_STREAMS = %w[ rooms ].freeze

  # Channel.channel_name for the RoomChannel subclasses that stream per room.
  ROOM_CHANNELS = %w[ room presence typing_notifications ].freeze

  USER_STREAM = /\Auser_(\d+)_(?:reads|unreads)\z/

  def initialize(user)
    @user = user
  end

  def authorized?(stream_name)
    name = stream_name.to_s
    return false if user.blank? || name.blank?

    return true if ACCOUNT_STREAMS.include?(name)

    if user_stream = USER_STREAM.match(name)
      return user.id == user_stream[1].to_i
    end

    prefix, suffix = name.split(":", 2)
    return false if suffix.blank?

    if ROOM_CHANNELS.include?(prefix)
      member_of_room? suffix
    else
      case suffix
      when "messages" then member_of_room? prefix
      when "rooms"    then own_user? prefix
      else false
      end
    end
  end

  private
    attr_reader :user

    def member_of_room?(gid_param)
      room = locate(gid_param, Room)
      room.present? && user.rooms.exists?(id: room.id)
    end

    def own_user?(gid_param)
      locate(gid_param, User) == user
    end

    def locate(gid_param, klass)
      GlobalID::Locator.locate gid_param, only: klass
    rescue ActiveRecord::RecordNotFound, URI::Error
      nil
    end
end
