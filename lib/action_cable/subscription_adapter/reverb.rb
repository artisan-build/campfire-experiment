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

      # Reverb refuses an HTTP API call whose whole body is over the
      # application's max message size — 10,000 bytes on Cloud, with no CLI flag
      # to raise it — and answers 413. Every Campfire message append is bigger
      # than that, because the message partial carries the boost UI and the
      # actions menu with it, so an uncompressed transport delivers typing and
      # unread events and drops the messages themselves. Deflate buys an order
      # of magnitude on Turbo Stream HTML, which puts a message well inside the
      # budget; app/javascript/lib/reverb/consumer.js inflates it.
      COMPRESSED_KEY = "__deflated"

      # Room for {"name":…,"channel":…,"data":…} and the JSON escaping of the
      # payload inside it.
      ENVELOPE_HEADROOM = 512

      def broadcast(channel, payload)
        pusher_channel = ReverbStream.channel_for(channel)

        if ReverbStream.too_long?(pusher_channel)
          logger.error "[reverb] stream #{channel.inspect} exceeds Pusher's #{ReverbStream::MAX_LENGTH}-character channel limit; not broadcast"
          return
        end

        ::ReverbClient.instance.trigger channel: pusher_channel, event: EVENT_NAME, data: encode(payload)
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

      private
        def encode(payload)
          return payload if payload.bytesize <= budget

          deflated = { COMPRESSED_KEY => Base64.strict_encode64(Zlib::Deflate.deflate(payload)) }.to_json
          logger.info "[reverb] deflated a #{payload.bytesize}-byte payload to #{deflated.bytesize} bytes (budget #{budget})"
          deflated
        end

        def budget
          ::ReverbClient.instance.max_message_size - ENVELOPE_HEADROOM
        end
    end
  end
end
