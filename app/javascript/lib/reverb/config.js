import ReverbConsumer from "lib/reverb/consumer"

// Present only when a Reverb server is attached; see ReverbHelper#reverb_meta_tag.
const meta = document.querySelector("meta[name=reverb-config]")

export const reverbConfig = meta?.content ? JSON.parse(meta.content) : null

let consumer = null

// One socket for the whole page: the stream source element and the Stimulus
// channels share it, exactly as they shared one Action Cable consumer.
export function reverbConsumer() {
  if (!reverbConfig) return null

  return consumer ??= new ReverbConsumer(reverbConfig)
}
