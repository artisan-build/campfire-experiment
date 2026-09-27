require "action_cable/subscription_adapter/base"

# An Action Cable subscription adapter that publishes to a Pusher-protocol
# server — Laravel Cloud's managed Reverb — instead of Redis.
#
# Every broadcast in Campfire funnels through #broadcast: Turbo Streams'
# broadcast_*_to (messages, boosts, the room list) and the two direct
# ActionCable.server.broadcast calls (unread rooms, read rooms). Swapping the
# adapter therefore moves the entire server-side realtime surface onto Reverb
# without editing a single call site.
#
# The subscribe half stays deliberately empty. Browsers talk to Reverb directly
# over the Pusher protocol and never open an Action Cable socket — which is the
# whole point, because Cloud's edge does not forward the `Upgrade` header to the
# app container. Action Cable's own server is still mounted and still healthy;
# nothing subscribes through it.
module ActionCable
  module SubscriptionAdapter
    class Reverb < Base
      EVENT_NAME = "action_cable"

      def broadcast(channel, payload)
        pusher_channel = ReverbStream.channel_for(channel)

        if ReverbStream.too_long?(pusher_channel)
          logger.error "[reverb] stream #{channel.inspect} exceeds Pusher's #{ReverbStream::MAX_LENGTH}-character channel limit; not broadcast"
          return
        end

        ::ReverbClient.instance.trigger channel: pusher_channel, event: EVENT_NAME, data: payload
      rescue ::ReverbClient::Error => e
        # A Reverb outage costs realtime updates; it must not also cost the
        # request that triggered the broadcast (posting a message, for one).
        logger.error "[reverb] broadcast to #{channel.inspect} (#{payload.to_s.bytesize} bytes) failed: #{e.message}"
      end

      def subscribe(channel, callback, success_callback = nil)
        success_callback&.call
      end

      def unsubscribe(channel, callback)
      end

      def shutdown
      end
    end
  end
end
