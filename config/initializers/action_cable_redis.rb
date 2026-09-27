# Laravel Cloud's managed Valkey restricts the ACL of the injected "application"
# user: CLIENT SETNAME is denied (NOPERM client|setname). Action Cable's default
# Redis connector passes an :id, which makes redis-rb call CLIENT SETNAME on
# connect and 500s every broadcast. Use a connector without the connection name.
require "action_cable/subscription_adapter/redis"

ActionCable::SubscriptionAdapter::Redis.redis_connector = ->(config) do
  ::Redis.new(config.except(:adapter, :channel_prefix, :id))
end
