module ReverbHelper
  # Rendered only when a Reverb server is attached. app/javascript/lib/reverb
  # takes over Turbo's cable transport when this tag is present and leaves
  # Action Cable alone when it isn't, so the same build runs both ways.
  def reverb_meta_tag
    return unless ReverbClient.configured?

    tag.meta name: "reverb-config", content: ReverbClient.instance.client_config.to_json
  end
end
