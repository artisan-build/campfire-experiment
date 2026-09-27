import Pusher from "pusher-js"
import { post } from "@rails/request.js"

// A stand-in for @rails/actioncable's Consumer, backed by the Pusher protocol.
//
// turbo-rails funnels every subscription — <turbo-cable-stream-source> and each
// cable.subscribeTo call in app/javascript/controllers — through
// consumer.subscriptions.create(params, mixin). Implementing that one method is
// enough to move the whole client onto Reverb without touching a call site.
//
// Channel names are resolved server side (POST /reverb/subscription) so that
// mapping Action Cable stream names onto Pusher channels stays in one place, in
// Ruby. See app/lib/reverb_stream.rb.

const RESOLVE_URL = "/reverb/subscription"
const AUTH_URL = "/reverb/auth"
const PERFORM_URL = "/reverb/perform"
const EVENT_NAME = "action_cable"

// Reverb caps a message at its application's max message size (10,000 bytes on
// Cloud), which every Campfire message append is over, so the adapter deflates
// anything near the limit and marks it with this key. See
// lib/action_cable/subscription_adapter/reverb.rb.
const COMPRESSED_KEY = "__deflated"

async function postJSON(url, body) {
  return post(url, { body, responseKind: "json" })
}

async function decodePayload(data) {
  if (data && typeof data === "object" && typeof data[COMPRESSED_KEY] === "string") {
    return JSON.parse(await inflate(data[COMPRESSED_KEY]))
  }

  return data
}

async function inflate(base64) {
  const bytes = Uint8Array.from(atob(base64), character => character.charCodeAt(0))
  const stream = new Blob([ bytes ]).stream().pipeThrough(new DecompressionStream("deflate"))

  return new Response(stream).text()
}

export default class ReverbConsumer {
  #pusher = null

  constructor(config) {
    this.config = config
    this.subscriptions = new Subscriptions(this)
    // refresh_room_controller reaches for consumer.connection.connection.monitor
    // to nudge a reconnect when the browser comes back online.
    this.connection = new Connection(this)
  }

  get pusher() {
    return this.#pusher ??= this.#createPusher()
  }

  #createPusher() {
    const pusher = new Pusher(this.config.key, {
      wsHost: this.config.host,
      wsPort: this.config.port,
      wssPort: this.config.port,
      forceTLS: this.config.forceTLS,
      enabledTransports: [ "ws", "wss" ],
      // pusher-js throws without a cluster even when wsHost is given; wsHost
      // wins, so this only has to be present.
      cluster: this.config.cluster,
      enableStats: false,
      channelAuthorization: { customHandler: authorizeChannel }
    })

    pusher.connection.bind("state_change", ({ current }) => {
      this.subscriptions.connectionStateChanged(current)
    })

    return pusher
  }
}

// Reverb signs private channels through Campfire's own session, so the request
// has to carry the CSRF token and cookies that @rails/request.js adds.
async function authorizeChannel({ socketId, channelName }, callback) {
  try {
    const response = await postJSON(AUTH_URL, { socket_id: socketId, channel_name: channelName })

    if (response.ok) {
      callback(null, await response.json)
    } else {
      callback(new Error(`Reverb refused ${channelName} (${response.statusCode})`), null)
    }
  } catch (error) {
    callback(error, null)
  }
}

class Subscriptions {
  #subscriptions = []

  constructor(consumer) {
    this.consumer = consumer
  }

  create(params, mixin) {
    const subscription = new ReverbSubscription(this.consumer, params, mixin)
    this.#subscriptions.push(subscription)
    return subscription
  }

  forget(subscription) {
    this.#subscriptions = this.#subscriptions.filter(candidate => candidate !== subscription)
  }

  connectionStateChanged(state) {
    this.#subscriptions.forEach(subscription => subscription.connectionStateChanged(state))
  }
}

class ReverbSubscription {
  #closed = false
  #connected = false
  #pusherChannel = null
  #onUnsubscribe = null
  // Inflating is asynchronous, and Turbo Streams have to be applied in the
  // order they arrived, so deliveries queue behind one another.
  #deliveries = Promise.resolve()

  constructor(consumer, params, mixin) {
    this.consumer = consumer
    this.params = params
    Object.assign(this, mixin)
    this.#start()
  }

  // Action Cable's own API: controllers call channel.send({ action: "start" }).
  send(data = {}) {
    const { action, ...rest } = data
    return this.perform(action, rest)
  }

  perform(action, data = {}) {
    if (!action) return Promise.resolve()

    return postJSON(PERFORM_URL, { ...this.params, channel_action: action, data })
  }

  unsubscribe() {
    if (this.#closed) return
    this.#closed = true

    if (this.#onUnsubscribe) this.perform(this.#onUnsubscribe)

    if (this.#pusherChannel) {
      this.consumer.pusher.unsubscribe(this.#pusherChannel.name)
      this.#pusherChannel = null
    }

    this.#markDisconnected()
    this.consumer.subscriptions.forget(this)
  }

  connectionStateChanged(state) {
    // A channelless subscription (HeartbeatChannel) reports the socket itself;
    // the others wait for Reverb to confirm the channel.
    if (state === "connected") {
      if (!this.#pusherChannel) this.#markConnected()
    } else {
      this.#markDisconnected()
    }
  }

  async #start() {
    const response = await postJSON(RESOLVE_URL, this.params)

    // A refused subscription is Action Cable's `reject`: stay quiet, stay dead.
    if (!response.ok || this.#closed) return

    const { channel, on_subscribe, on_unsubscribe } = await response.json
    if (this.#closed) return

    this.#onUnsubscribe = on_unsubscribe

    if (channel) {
      this.#pusherChannel = this.consumer.pusher.subscribe(channel)
      this.#pusherChannel.bind("pusher:subscription_succeeded", () => this.#markConnected())
      this.#pusherChannel.bind("pusher:subscription_error", status => {
        console.error(`[reverb] could not subscribe to ${channel}`, status)
        this.#markDisconnected()
      })
      this.#pusherChannel.bind(EVENT_NAME, data => this.#deliver(data))
    } else {
      this.consumer.pusher.connect()
      if (this.consumer.pusher.connection.state === "connected") this.#markConnected()
    }

    if (on_subscribe) this.perform(on_subscribe)
  }

  #deliver(data) {
    this.#deliveries = this.#deliveries
      .then(async () => this.received?.(await decodePayload(data)))
      .catch(error => console.error("[reverb] could not deliver a message", error))
  }

  #markConnected() {
    if (this.#connected || this.#closed) return

    this.#connected = true
    this.connected?.()
  }

  #markDisconnected() {
    if (!this.#connected) return

    this.#connected = false
    this.disconnected?.()
  }
}

// Just enough of Action Cable's connection monitor for
// refresh_room_controller#online to ask for a reconnect.
class Connection {
  constructor(consumer) {
    this.consumer = consumer
    this.monitor = { visibilityDidChange: () => consumer.pusher.connect() }
  }

  get state() {
    return this.consumer.pusher.connection.state
  }
}
