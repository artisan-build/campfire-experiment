import { cable } from "@hotwired/turbo-rails"
import { reverbConsumer } from "lib/reverb/config"

// Hand the Stimulus channels (presence, typing, read/unread rooms, heartbeat)
// the same Reverb-backed consumer the stream sources use. Import this AFTER
// @hotwired/turbo-rails; lib/reverb/stream_source goes before it.
const consumer = reverbConsumer()

if (consumer) cable.setConsumer(consumer)
