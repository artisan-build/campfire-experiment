# Point Action Cable's broadcasts at Cloud's managed Reverb whenever one is
# attached, rather than editing config/cable.yml — keeping an upstream file out
# of the diff and making the swap self-activating. With no REVERB_* variables in
# the environment (development, test, CI) the Redis adapter and Action Cable's
# own WebSocket stay in place, untouched.
Rails.application.config.after_initialize do
  if ReverbClient.configured?
    ActionCable.server.config.cable = { "adapter" => "reverb" }
    Rails.logger.info "[reverb] Action Cable broadcasting through Reverb at #{ENV['REVERB_HOST']}"
  end
end
