import { reverbConfig, reverbConsumer } from "lib/reverb/config"

// Campfire's own <turbo-cable-stream-source>, subscribing over Reverb.
//
// turbo-rails defines this element in its module body, and by then the elements
// are already in the document, so its first subscription can be raced away
// before a replacement consumer is installed — which is how three stream
// sources ended up on a dead wss://…/cable. turbo-rails guards its own define
// (`if (customElements.get(...) === undefined)`), so claiming the name first
// leaves nothing to race: import this module before @hotwired/turbo-rails.
//
// Messages are handed to Turbo.renderStreamMessage, which is what
// connectStreamSource's own listener does with them; going straight there means
// this element needs nothing from Turbo at definition time.
class ReverbStreamSourceElement extends HTMLElement {
  static observedAttributes = [ "channel", "signed-stream-name" ]

  async connectedCallback() {
    this.subscription = reverbConsumer().subscriptions.create(this.channel, {
      received: data => window.Turbo?.renderStreamMessage(data),
      connected: () => this.setAttribute("connected", ""),
      disconnected: () => this.removeAttribute("connected")
    })
  }

  disconnectedCallback() {
    this.subscription?.unsubscribe()
    this.subscription = null
    this.removeAttribute("connected")
  }

  attributeChangedCallback() {
    if (this.subscription) {
      this.disconnectedCallback()
      this.connectedCallback()
    }
  }

  get channel() {
    return {
      channel: this.getAttribute("channel"),
      signed_stream_name: this.getAttribute("signed-stream-name"),
      ...snakeize({ ...this.dataset })
    }
  }
}

// turbo-rails passes a stream source's data attributes through as snake_case
// channel parameters; mirror that so `data-room-id` still arrives as room_id.
function snakeize(object) {
  return Object.fromEntries(
    Object.entries(object).map(([ key, value ]) => [ key.replace(/[A-Z]/g, letter => `_${letter.toLowerCase()}`), value ])
  )
}

if (reverbConfig && customElements.get("turbo-cable-stream-source") === undefined) {
  customElements.define("turbo-cable-stream-source", ReverbStreamSourceElement)
}
