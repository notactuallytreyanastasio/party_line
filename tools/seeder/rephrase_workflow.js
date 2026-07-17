export const meta = {
  name: 'rephrase-seeds',
  description: 'Haiku agents rephrase scrubbed reddit titles into original, labelled party-line topics',
  phases: [{ title: 'Rephrase', detail: 'one Haiku agent per batch of ~90 titles' }],
}

const SCHEMA = {
  type: 'object',
  required: ['topics'],
  properties: {
    topics: {
      type: 'array',
      description: 'one rewritten topic per input title, same order',
      items: {
        type: 'object',
        required: ['topic', 'label'],
        properties: {
          topic: { type: 'string', description: 'the rewritten party-line topic' },
          label: {
            type: 'string',
            enum: ['none', 'nsfw', 'heavy'],
            description: 'nsfw = sexual/explicit; heavy = dark/tragic/abuse; none otherwise',
          },
        },
      },
    },
  },
}

phase('Rephrase')
const batches = typeof args === 'string' ? JSON.parse(args) : args
log(`rephrasing ${batches.length} batches`)

const results = await parallel(
  batches.map((batch, i) => () =>
    agent(
      `You are writing discussion topics for "party line" — chat rooms where eccentric AI personalities (a horse dentist, a cryptid defense attorney, a coupon warlock) riff on a nightly topic while humans lurk and drop in.

Below are ${batch.length} raw forum post titles as [subreddit, title] pairs. Rewrite EACH ONE into a single original discussion topic for a party-line room, and tag it.

Hard rules:
- STRIP every trace of the source: no "reddit", "redditor", "subreddit", "r/x", "u/name", "OP/OOP", "AITA/AITAH/TIFU/TIL/BORU" prefixes, no "karma", "upvote", "edit:", "[deleted]", "AMA". Nobody should be able to tell these came from a forum.
- Make it ORIGINAL — capture the spirit/question, but rephrase freely. Not a copy.
- Make it a great room prompt: provocative, funny, or genuinely curious; something weird personalities would argue about. 3-16 words. lowercase-casual is fine. No hashtags, no surrounding quotes.
- AITAH-style -> a judgment call ("was it wrong to ..."). TIFU-style -> a confession/cautionary hook. TIL-style -> a "is this real / what if" hook. AskReddit-style -> keep it a question. Updates -> an open "whatever happened when ..." hook.
- LABEL each: "nsfw" if sexual/explicit, "heavy" if dark/tragic/abuse/self-harm, else "none". Do NOT skip or sanitize away the interesting ones — keep the topic true to the source and just label it. (nsfw/heavy topics are fine; the label gates them.)
- One item per input, SAME ORDER. Return exactly ${batch.length} items.

Titles:
${batch.map(([s, t], n) => `${n + 1}. [${s}] ${t}`).join('\n')}`,
      { label: `batch:${i}`, phase: 'Rephrase', model: 'haiku', schema: SCHEMA }
    ).then((r) => (r && r.topics ? r.topics : []))
  )
)

const seen = new Set()
const topics = []
for (const t of results.filter(Boolean).flat()) {
  const topic = (t.topic || '').trim()
  const label = t.label || 'none'
  if (topic.length >= 3 && topic.toUpperCase() !== 'SKIP' && !seen.has(topic.toLowerCase())) {
    seen.add(topic.toLowerCase())
    topics.push({ topic, label })
  }
}
log(`collected ${topics.length} unique topics (${topics.filter((t) => t.label !== 'none').length} labelled)`)
return { topics }
