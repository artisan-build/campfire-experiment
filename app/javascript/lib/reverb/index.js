import { cable } from "@hotwired/turbo-rails"
import ReverbConsumer from "lib/reverb/consumer"

// Swap Turbo's Action Cable consumer for a Pusher one when a Reverb server is
// attached (see ReverbHelper#reverb_meta_tag). This runs while modules are still
// being evaluated, before customElements.define's upgrade reactions are
// processed off the microtask queue, so the first <turbo-cable-stream-source> on
// the page already sees the replacement.
const meta = document.querySelector("meta[name=reverb-config]")

if (meta?.content) {
  cable.setConsumer(new ReverbConsumer(JSON.parse(meta.content)))
}
