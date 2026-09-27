# Maps Action Cable broadcasting names onto Pusher channel names, reversibly.
#
# Action Cable stream names are arbitrary strings ("user_5_unreads",
# "Z2lkOi8vY2FtcGZpcmUvUm9vbS8z:messages"). Pusher channel names may only hold
# [A-Za-z0-9_\-=@,.;], cap at 164 characters, and need a "private-" prefix to
# require authentication. URL-safe Base64 fits inside that alphabet, so this is
# an encoding rather than a lookup table: the broadcaster and the
# authentication endpoint each derive one name from the other with no shared
# state, and a channel name a client invents still decodes to the stream it is
# really asking for.
class ReverbStream
  PREFIX = "private-ac-"
  MAX_LENGTH = 164

  class << self
    def channel_for(stream_name)
      PREFIX + Base64.urlsafe_encode64(stream_name.to_s, padding: false)
    end

    def stream_for(channel_name)
      encoded = channel_name.to_s.delete_prefix(PREFIX)
      return nil if encoded == channel_name.to_s || encoded.blank?

      Base64.urlsafe_decode64(encoded).force_encoding(Encoding::UTF_8).scrub
    rescue ArgumentError
      nil
    end

    def too_long?(channel_name)
      channel_name.to_s.length > MAX_LENGTH
    end
  end
end
